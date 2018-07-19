#!/bin/bash
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# Copyright (c) 2018 Joyent, Inc.
#

#
# Setup a prom/grafana in COAL (or another headnode) for admin zones.
#

IMAGE_UUID="7b5981c4-1889-11e7-b4c5-3f3bdfc9b88b" # LX Ubuntu 16.04
MIN_MEMORY=2048
PROMETHEUS_VERSION="2.3.0"
ALIAS=prometheus0

HOST=$1
if [[ -z ${HOST} ]]; then
    HOST="coal"
fi

# Code in this block runs on the remote system
ssh ${HOST} <<EOF
. ~/.bash_profile

if [[ -n "${TRACE}" ]]; then
    set -o xtrace
fi

# It's ok for this to fail if we already have the image
sdc-imgadm import -S https://images.joyent.com ${IMAGE_UUID} </dev/null

# Setup for CNS to work
# XXX change to not mod if already set
sdc-useradm replace-attr admin approved_for_provisioning true </dev/null
sdc-useradm replace-attr admin triton_cns_enabled true </dev/null
sdc-login -l cns "svcadm restart cns-updater" </dev/null
# XXX What's the point of this one? To ensure it looks right? To force a cache warm in CNS?
sdc-login -l cns "cnsadm vm \$(vmadm lookup alias=vmapi0)" </dev/null

# XXX can we get this to the top?
set -o errexit

# need to provision to headnode so we can zlogin
headnode_uuid=\$(sysinfo | json UUID)

# Find admin uuid
admin_uuid=\$(sdc-useradm get admin | json uuid)

# Find network (we want to be on same one as cmon)
network_uuid=\$(vmadm get \$(vmadm lookup alias=~^cmon | head -1) | json nics.1.network_uuid)
admin_network_uuid=\$(sdc-napi /networks?name=admin | json -H 0.uuid)

# Find package
# XXX perhaps limit to the 'sdc_' packages.
package=\$(sdc-papi /packages | json -Ha uuid max_physical_memory | sort -n -k 2 \
    | while read uuid mem; do

    # Find the first one with at least ${MIN_MEMORY}
    if [[ -z \${pkg} && \${mem} -ge ${MIN_MEMORY} ]]; then
        pkg=\${uuid}
        echo \${uuid}
    fi
done)

# Find CNS resolver(s)
prometheus_dc=\$(bash /lib/sdc/config.sh -json | json datacenter_name)
prometheus_domain=\$(bash /lib/sdc/config.sh -json | json dns_domain)
cns_resolvers=\$(dig +noall +answer +short @binder.\${prometheus_dc}.\${prometheus_domain} cns.\${prometheus_dc}.\${prometheus_domain} |  tr '\n' ',' | sed -e "s/,$//")

echo "Admin: \${admin_uuid}"
echo "Network: \${network_uuid}"
echo "Package: \${package}"
echo "CNS Resolvers: \${cns_resolvers}"

# Note that until TRITON-605 is resolved, net-agent will likely be undoing
# our explicit "resolvers" below. As a workaround we'll have a user-script
# that sorts it out on boot (see ./boot/configure.sh for a future
# alternative to this user-script).
echo "Creating VM ${ALIAS} ..."
vm_uuid=\$((sdc-vmapi /vms?sync=true -X POST -d@/dev/stdin | json -H vm_uuid) <<PAYLOAD
{
    "alias": "${ALIAS}",
    "billing_id": "\${package}",
    "brand": "lx",
    "image_uuid": "${IMAGE_UUID}",
    "networks": [{"uuid": "\${admin_network_uuid}"}, {"uuid": "\${network_uuid}", "primary": true}],
    "owner_uuid": "\${admin_uuid}",
    "resolvers": ["\$(echo "\${cns_resolvers},8.8.8.8" | sed -e 's/,/","/g')"],
    "server_uuid": "\${headnode_uuid}",
    "customer_metadata": {
        "cnsResolvers": "\${cns_resolvers}",
        "user-script": "#!/bin/bash\n\nset -o errexit\nset -o pipefail\nset -o xtrace\n\nmdata-get cnsResolvers | tr , '\n' | while read ip; do\n        grep \"^nameserver \\\$ip$\" /etc/resolvconf/resolv.conf.d/head >/dev/null 2>&1 || echo \"nameserver \\\$ip\" >> /etc/resolvconf/resolv.conf.d/head;\n    done\nresolvconf -u\n\nexit 0\n"
    }
}
PAYLOAD
)

# Download the bits (since external resolvers not setup in zone)
cd /zones/\${vm_uuid}/root/root
curl -L -kO https://github.com/prometheus/prometheus/releases/download/v${PROMETHEUS_VERSION}/prometheus-${PROMETHEUS_VERSION}.linux-amd64.tar.gz
tar -zxvf prometheus-${PROMETHEUS_VERSION}.linux-amd64.tar.gz
ln -s prometheus-${PROMETHEUS_VERSION}.linux-amd64 prometheus
cd prometheus

# Generate/Register Cert/Key
ssh-keygen -t rsa -f prometheus_key -N ''
openssl rsa -in prometheus_key -outform pem >prometheus_key.priv.pem
openssl req -new -key prometheus_key.priv.pem -out prometheus_key.csr.pem -subj "/CN=admin"
openssl x509 -req -days 365 -in prometheus_key.csr.pem -signkey prometheus_key.priv.pem -out prometheus_key.pub.pem
/opt/smartdc/bin/sdc-useradm add-key -f admin prometheus_key.pub

# Generate Config
# XXX Joshw's config for 'endpoint' below uses 'cmon.us-east-stg-1b.scloud.zone'.
#     How could that be discovered via script?
prometheus_ip=\$(vmadm get \${vm_uuid} | json nics.1.ip)
cns_zone="\${prometheus_dc}.cns.\${prometheus_domain}"

cp prometheus.yml prometheus.yml.bak
cat >prometheus.yml <<PROMYML
# my global config
global:
  scrape_interval:     15s # Set the scrape interval to every 15 seconds. Default is every 1 minute.
  evaluation_interval: 15s # Evaluate rules every 15 seconds. The default is every 1 minute.
  # scrape_timeout is set to the global default (10s).

scrape_configs:
  - job_name: 'admin_\${prometheus_dc}'
    scheme: https
    tls_config:
      cert_file: /root/prometheus/prometheus_key.pub.pem
      key_file: /root/prometheus/prometheus_key.priv.pem
      insecure_skip_verify: true
    relabel_configs:
      - source_labels: [__meta_triton_machine_alias]
        target_label: instance
    triton_sd_configs:
      - account: 'admin'
        dns_suffix: 'cmon.\${cns_zone}'
        endpoint: 'cmon.\${cns_zone}'
        version: 1
        tls_config:
          cert_file: /root/prometheus/prometheus_key.pub.pem
          key_file: /root/prometheus/prometheus_key.priv.pem
          insecure_skip_verify: true
PROMYML

# Generate systemd manifest
cat >/zones/\${vm_uuid}/root/etc/systemd/system/prometheus.service <<SYSTEMD
[Unit]
    Description=Prometheus server
    After=network.target

[Service]
    WorkingDirectory=/root/prometheus
    StandardOutput=syslog
    ExecStart=/root/prometheus/prometheus \\
        --storage.tsdb.path=/root/prometheus/data \\
        --config.file=/root/prometheus/prometheus.yml \\
        --web.external-url=http://\${prometheus_ip}:9090/
    User=root

[Install]
    WantedBy=multi-user.target
SYSTEMD

zlogin \${vm_uuid} "systemctl daemon-reload && systemctl enable prometheus && systemctl start prometheus && systemctl status prometheus" </dev/null


# Grafana setup
# - For now auth is 'admin/admin'.
# - TODO: could attempt to get auth.ldap working, or auth.proxy via a local
#   proxy that talks to mahi/ufds to allow operators in.
#   See http://docs.grafana.org/tutorials/authproxy/ and/or
#   http://docs.grafana.org/installation/behind_proxy/
# - TODO: an update plan: http://docs.grafana.org/installation/upgrading/
#   Perhaps a delegate dataset and persisted data there, or can we be
#   stateless with preconfig? I hope so.
#
(
    cd /tmp;
    wget https://s3-us-west-2.amazonaws.com/grafana-releases/release/grafana_5.1.4_amd64.deb;
    apt-get install -y adduser libfontconfig;
    dpkg -i grafana_5.1.4_amd64.deb;
)

cp /etc/grafana/grafana.ini /etc/grafana/grafana.ini.orig
cat >/etc/grafana/grafana.ini <<GRAFANACONFIG
[auth.anonymous]
enabled = true
org_name = Main Org.
org_role = Viewer
GRAFANACONFIG


echo "Links:"
echo "- prometheus server: http://\${prometheus_ip}:9090/"
echo "- a sample graph: http://\${prometheus_ip}:9090/graph?g0.range_input=1h&g0.expr=cpucap_cur_usage_percentage%7Binstance%3D~%22cnapi.%22%7D&g0.tab=0
echo "- grafana server: http://\${prometheus_ip}:3000/"

EOF
