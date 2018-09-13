#!/bin/bash
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# Copyright (c) 2018 Joyent, Inc.
#

#
# This tool works to set up grafana on an LX zone in a production environment.
# From the global zone, run ./setup-grafana.sh as root. A prometheus zone must
# already exist.
#
# Afterwards, it will print the Grafana URL. It is provisioned with the
# latest dashboards defined in https://github.com/joyent/triton-dashboards.
# It takes a few minutes for the discovery process to complete before
# you'll see any metrics.
#

IMAGE_UUID="7b5981c4-1889-11e7-b4c5-3f3bdfc9b88b" # LX Ubuntu 16.04
MIN_MEMORY=1024
GRAFANA_VERSION="5.2.2"
ALIAS=grafana0

if [[ $# -ne 0 ]]; then
    echo "usage: ./setup-grafana.sh" >&2
fi

set -o errexit
set -o pipefail
if [[ -n "${TRACE}" ]]; then
    set -o xtrace
fi

function fatal() {
    echo "FATAL: $*" >&2
    exit 1
}

. ~/.bash_profile

#
# grafana0 zone creation
#

vm_uuid=$(vmadm lookup alias=$ALIAS)
[[ -z "$vm_uuid" ]] || fatal "VM $ALIAS already exists"

if ! sdc-imgadm get ${IMAGE_UUID} >/dev/null 2>&1; then
    sdc-imgadm import -S https://images.joyent.com ${IMAGE_UUID} </dev/null
fi

headnode_uuid=$(sysinfo | json UUID)
admin_uuid=$(sdc-useradm get admin | json uuid)

external_network_uuid=$(sdc-napi /networks?name=external | json -H 0.uuid)
admin_network_uuid=$(sdc-napi /networks?name=admin | json -H 0.uuid)

# Find package
package=$(sdc-papi /packages | json -Ha uuid max_physical_memory | sort -n -k 2 \
    | while read uuid mem; do

    # Find the first one with at least ${MIN_MEMORY}
    if [[ -z ${pkg} && ${mem} -ge ${MIN_MEMORY} ]]; then
        pkg=${uuid}
        echo ${uuid}
    fi
done)

prometheus_ip=$(vmadm lookup -1 alias=prometheus0 -j \
    | json 0.nics | json -c 'this.nic_tag === "admin"' 0.ip)
[[ -n "$prometheus_ip" ]] \
    || fatal "could not find prometheus0 zone admin IP: have you setup a prometheus0 zone?"

echo "Admin account: ${admin_uuid}"
echo "Admin network: ${admin_network_uuid}"
echo "External network: ${external_network_uuid}"
echo "Headnode: ${headnode_uuid}"
echo "Package: ${package}"
echo "Alias: ${ALIAS}"

[[ -n "${admin_uuid}" ]] || fatal "missing admin UUID"
[[ -n "${headnode_uuid}" ]] || fatal "missing headnode UUID"
[[ -n "${admin_network_uuid}" ]] || fatal "missing admin network UUID"
[[ -n "${package}" ]] || fatal "missing package"

# - networks: Need the 'admin' to access the prometheus0 zone. Need 'external'
#   so, in general, an operator can reach it. WARNING: Need an auth story here.
# - tags.smartdc_role: So 'sdc-login -l graf' works.
echo "Creating VM ${ALIAS} ..."
vm_uuid=$((sdc-vmapi /vms?sync=true -X POST -d@/dev/stdin | json -H vm_uuid) <<PAYLOAD
{
    "alias": "${ALIAS}",
    "billing_id": "${package}",
    "brand": "lx",
    "image_uuid": "${IMAGE_UUID}",
    "networks": [{"uuid": "${admin_network_uuid}"}],
    "owner_uuid": "${admin_uuid}",
    "server_uuid": "${headnode_uuid}",
    "tags": {
        "smartdc_role": "grafana"
    }
}
PAYLOAD
)

#
# Grafana setup.
#

grafana_ip=$(vmadm get ${vm_uuid} | json nics.0.ip)

# Get the latest https://github.com/joyent/triton-dashboards
cd /zones/${vm_uuid}/root/root
curl -Lk -o triton-dashboards-master.tgz https://github.com/joyent/triton-dashboards/archive/master.tar.gz
gtar -zxvf triton-dashboards-master.tgz
mv triton-dashboards-master triton-dashboards

# Setup grafana.
cd /zones/${vm_uuid}/root/root
curl -L -kO https://s3-us-west-2.amazonaws.com/grafana-releases/release/grafana-${GRAFANA_VERSION}.linux-amd64.tar.gz
gtar -zxvf grafana-${GRAFANA_VERSION}.linux-amd64.tar.gz
ln -s grafana-${GRAFANA_VERSION} grafana
cd grafana

cat >./conf/provisioning/datasources/triton.yaml <<DATAYML
# config file version
apiVersion: 1

datasources:
    - name: Triton
      type: prometheus
      access: proxy
      orgId: 1
      url: http://${prometheus_ip}:9090
      isDefault: true
      editable: true
DATAYML

cat >./conf/provisioning/dashboards/triton.yaml <<DASHYML
# config file version
apiVersion: 1

providers:
    - name: Triton
      orgId: 1
      folder: ''
      type: file
      options:
        path: /root/triton-dashboards/dashboards
DASHYML

# Generate grafana systemd manifest
cat >/zones/${vm_uuid}/root/etc/systemd/system/grafana.service <<SYSTEMD
[Unit]
	Description=Grafana server
	After=network.target

[Service]
	WorkingDirectory=/root/grafana
	StandardOutput=syslog
	ExecStart=/root/grafana/bin/grafana-server
	User=root

[Install]
	WantedBy=multi-user.target
SYSTEMD

zlogin ${vm_uuid} "systemctl daemon-reload && systemctl enable grafana && systemctl start grafana && systemctl status grafana" </dev/null

# Unrefined method to allow grafana to start and provision the dashboards.
# Would be better to poll the curl attempts below.
sleep 5

# Set the CNAPI dashboard (for now) as the default org dashboard.
dashId=$(curl -sSf -u admin:admin "${grafana_ip}:3000/api/search?type=dash-db&query=cnapi" | json 0.id)
curl -sSf -u admin:admin ${grafana_ip}:3000/api/org/preferences -H content-type:application/json \
    -d '{"theme":"","homeDashboardId":'$dashId',"timezone":"utc"}' -X PUT
echo ""


echo ""
echo "* * * Successfully setup * * *"
echo "Prometheus: http://${prometheus_ip}:9090/"
echo "Grafana: http://${grafana_ip}:3000/ (admin:admin)"
