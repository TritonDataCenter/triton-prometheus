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
PACKAGE_UUID="4769a8f9-de51-4c1e-885f-c3920cc68137" # sdc_1024
GRAFANA_VERSION="5.2.2"
ALIAS=grafana0
PORT=443
NODE_VERSION="8.12.0"

if [[ $# -gt 1 ]]; then
    echo "usage: ./setup-grafana.sh [<non-local server uuid>]" >&2
    exit 1
fi

server_uuid=$1
if [[ -z "$server_uuid" ]]; then
    server_uuid=$(sysinfo | json UUID) # local headnode by default
fi

set -o errexit
set -o pipefail

if [[ -n "${TRACE}" ]]; then
    set -o xtrace
fi

if [[ -z ${SSH_OPTS} ]]; then
    SSH_OPTS=""
fi

function fatal() {
    echo "FATAL: $*" >&2
    exit 1
}

. ~/.bash_profile

#
# grafana0 zone creation
#
admin_uuid=$(sdc-useradm get admin | json uuid)

[[ -n $(sdc-server lookup uuid=${server_uuid}) ]] || fatal "Invalid server UUID"

vm_uuid=$(sdc-vmadm list alias=$ALIAS owner_uuid=${admin_uuid} -H -o uuid)
[[ -z "$vm_uuid" ]] || fatal "VM $ALIAS already exists"

if ! sdc-imgadm get ${IMAGE_UUID} >/dev/null 2>&1; then
    sdc-imgadm import -S https://images.joyent.com ${IMAGE_UUID} </dev/null
fi

external_network_uuid=$(sdc-napi /networks?name=external | json -H 0.uuid)
admin_network_uuid=$(sdc-napi /networks?name=admin | json -H 0.uuid)

# Find package
[[ -n $(sdc-papi /packages | json -Ha uuid | grep $PACKAGE_UUID) ]] || fatal "missing package"

prometheus_ip=$(sdc-vmadm list alias=prometheus0 owner_uuid=${admin_uuid} -j \
    | json 0.nics | json -c 'this.nic_tag === "admin"' 0.ip)
[[ -n "$prometheus_ip" ]] \
    || fatal "could not find prometheus0 zone admin IP: have you setup a prometheus0 zone?"

echo "Admin account: ${admin_uuid}"
echo "Admin network: ${admin_network_uuid}"
echo "Server: ${server_uuid}"
echo "Alias: ${ALIAS}"

[[ -n "${admin_uuid}" ]] || fatal "missing admin UUID"
[[ -n "${admin_network_uuid}" ]] || fatal "missing admin network UUID"

# - networks: Need the 'admin' to access the prometheus0 zone. Need 'external'
#   so, in general, an operator can reach it.
# - tags.smartdc_role: So 'sdc-login -l graf' works.
echo "Creating VM ${ALIAS} ..."
vm_uuid=$((sdc-vmapi /vms?sync=true -X POST -d@/dev/stdin | json -H vm_uuid) <<PAYLOAD
{
    "alias": "${ALIAS}",
    "billing_id": "${PACKAGE_UUID}",
    "brand": "lx",
    "image_uuid": "${IMAGE_UUID}",
    "networks": [{"uuid": "${admin_network_uuid}"}, {"uuid": "${external_network_uuid}", "primary": true}],
    "owner_uuid": "${admin_uuid}",
    "server_uuid": "${server_uuid}",
    "tags": {
        "smartdc_role": "grafana"
    }
}
PAYLOAD
)

#
# Grafana setup.
#

grafana_ip=$(sdc-vmadm get ${vm_uuid} | json nics.1.ip)
server_ip=$(sdc-server admin-ip ${server_uuid} | head -1)

# Download dashboards, grafana, node into the zone
ssh ${SSH_OPTS} ${server_ip} <<SERVER
cd /zones/${vm_uuid}/root/root

# Download dashboards, grafana, node
curl -Lk -o triton-dashboards-master.tgz https://github.com/joyent/triton-dashboards/archive/master.tar.gz
tar -zxvf triton-dashboards-master.tgz
mv triton-dashboards-master triton-dashboards

curl -L -kO https://s3-us-west-2.amazonaws.com/grafana-releases/release/grafana-${GRAFANA_VERSION}.linux-amd64.tar.gz
tar -zxvf grafana-${GRAFANA_VERSION}.linux-amd64.tar.gz
ln -s grafana-${GRAFANA_VERSION} grafana

curl -L -kO https://nodejs.org/download/release/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.gz
tar -zxvf node-v${NODE_VERSION}-linux-x64.tar.gz
ln -s node-v${NODE_VERSION}-linux-x64 node
ln -s /root/node/bin/node /zones/${vm_uuid}/root/usr/bin/node

cd grafana

# Generate/Register Cert/Key
openssl req -x509 -nodes -subj "/CN=${grafana_ip}" -newkey rsa:2048 \
    -keyout grafana_key.pem -out grafana_cert.pem -days 365

cat >./conf/custom.ini <<CONFIGINI
# config file version
apiVersion: 1

[server]
  http_port=${PORT}
  protocol=https
  cert_file=/root/grafana/grafana_cert.pem
  cert_key=/root/grafana/grafana_key.pem
CONFIGINI

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

cat > ./redir.js <<REDIRJS
#!/usr/bin/env node

/*
 *
 * Copyright 2018 Joyent Inc.
 *
 * http redirection for grafana.
 *
 */

var http = require('http');

if (process.argv.length != 2) {
  console.error("Usage: node redir.js")
  process.exit(1)
}

http.createServer(function(req, res) {
  res.statusCode = 301;
  res.setHeader("Location", "https://" + req.headers.host + req.url);
  res.end();
}).listen(80);
REDIRJS

chmod 700 ./redir.js

cat > ./wrapper.sh <<WRAPPER
#!/bin/bash
/root/grafana/redir.js &
/root/grafana/bin/grafana-server
WRAPPER

chmod 700 ./wrapper.sh

# Generate grafana systemd manifest
cat > /zones/${vm_uuid}/root/etc/systemd/system/grafana.service <<SYSTEMD
[Unit]
	Description=Grafana server
	After=network.target

[Service]
	WorkingDirectory=/root/grafana
	StandardOutput=syslog
	ExecStart=/root/grafana/wrapper.sh
	User=root

[Install]
  WantedBy=multi-user.target
SYSTEMD

zlogin ${vm_uuid} "systemctl daemon-reload && systemctl enable grafana && systemctl start grafana && systemctl status grafana" < /dev/null

# Unrefined method to allow grafana to start and provision the dashboards.
# Would be better to poll the curl attempts below.
sleep 5

# Set the CNAPI dashboard (for now) as the default org dashboard.
cert="/zones/${vm_uuid}/root/root/grafana/grafana_cert.pem"
curl -sSf --cacert \${cert} -u admin:admin \
    "https://${grafana_ip}:${PORT}/api/search?type=dash-db&query=cnapi"
dashId=\$(curl -sSf --cacert \${cert} -u admin:admin \
    "https://${grafana_ip}:${PORT}/api/search?type=dash-db&query=cnapi" | json 0.id)
curl -sSf --cacert \${cert} -u admin:admin \
    "https://${grafana_ip}:${PORT}/api/org/preferences" -H content-type:application/json \
    -d '{"theme":"","homeDashboardId":'\$dashId',"timezone":"utc"}' -X PUT

# Change the default password
pw=\$(openssl rand -base64 32 | tr -d "=+/")
echo \$pw > /zones/${vm_uuid}/root/root/grafana/password.txt

curl -sSf --cacert \${cert} -u admin:admin \
    "https://${grafana_ip}:${PORT}/api/user/password" -H content-type:application/json \
    -d '{"oldPassword":"admin","newPassword":'\"\${pw}\"',"confirmNew":'\"\${pw}\"'}' -X PUT
SERVER

echo ""
echo "* * * Successfully setup * * *"
echo "Prometheus: http://${prometheus_ip}:9090/"
echo "Grafana: https://${grafana_ip} (username = admin; password in ${ALIAS} zone in /root/grafana/password.txt)"
