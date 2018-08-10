#!/bin/bash
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# Copyright (c) 2018 Joyent, Inc.
#

#
# This tool works to setup prometheus (and required cmon/cns bits) on a test
# machine which has been setup with trentops:bin/coal-post-setup.sh or another
# similar mechanism (e.g. globe-theatre nightly setup).
#
# On a new coal, run coal-post-setup.sh, then:
#
#  ./tools/setup-prom.sh coal
#
# and you should be able to then go to the prometheus page that gets spit out at
# the end. It takes a few minutes though for the discovery process to complete
# before you'll see any metrics.
#

IMAGE_UUID="7b5981c4-1889-11e7-b4c5-3f3bdfc9b88b" # LX Ubuntu 16.04
MIN_MEMORY=1024
PROMETHEUS_VERSION="2.3.2"
ALIAS=prometheus0

HOST=$1
if [[ -z "$HOST" ]]; then
    echo "error: missing HEADNODE-GZ argument" >&2
    echo "usage: ./setup-prometheus.sh HEADNODE-GZ" >&2
    exit 1
fi

if [[ -z ${SSH_OPTS} ]]; then
    SSH_OPTS=""
fi

# Code in this block runs on the remote system
ssh ${SSH_OPTS} ${HOST} <<EOF

set -o errexit
if [[ -n "${TRACE}" ]]; then
    set -o xtrace
fi

function fatal() {
    echo "FATAL: \$*" >&2
    exit 1
}

. ~/.bash_profile


#
# prometheus0 zone creation
#

vm_uuid=\$(vmadm lookup alias=$ALIAS)
[[ -z "\$vm_uuid" ]] || fatal "VM $ALIAS already exists"

if ! sdc-imgadm get ${IMAGE_UUID} >/dev/null 2>&1; then
    sdc-imgadm import -S https://images.joyent.com ${IMAGE_UUID} </dev/null
fi

# Setup for CNS to actually work
sdc-useradm replace-attr admin approved_for_provisioning true </dev/null
sdc-useradm replace-attr admin triton_cns_enabled true </dev/null
sdc-login -l cns "svcadm restart cns-updater" </dev/null
sdc-login -l cns "cnsadm vm \$(vmadm lookup alias=vmapi0)" </dev/null

set -o errexit

# need to provision to headnode so we can zlogin
headnode_uuid=\$(sysinfo | json UUID)

# Find admin uuid
admin_uuid=\$(sdc-useradm get admin | json uuid)

# Find network (we want to be on same one as cmon)
network_uuid=\$(vmadm get \$(vmadm lookup alias=~^cmon | head -1) | json nics.1.network_uuid)
admin_network_uuid=\$(sdc-napi /networks?name=admin | json -H 0.uuid)

# Find package
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

binder_resolvers=\$(dig +short binder.\${prometheus_dc}.\${prometheus_domain} | tr '\n' ',' | sed -e "s/,$//")
cns_resolvers=\$(dig +noall +answer +short @binder.\${prometheus_dc}.\${prometheus_domain} cns.\${prometheus_dc}.\${prometheus_domain} | tr '\n' ',' | sed -e "s/,$//")

echo "Admin account: \${admin_uuid}"
echo "Admin network: \${admin_network_uuid}"
echo "Headnode: \${headnode_uuid}"
echo "Network: \${network_uuid}"
echo "Package: \${package}"
echo "Alias: ${ALIAS}"
echo "CNS Resolvers: \${cns_resolvers}"
echo "Binder Resolvers: \${binder_resolvers}"

[[ -n "\${admin_uuid}" ]] || fatal "missing admin UUID"
[[ -n "\${headnode_uuid}" ]] || fatal "missing headnode UUID"
[[ -n "\${network_uuid}" ]] || fatal "missing CMON network UUID"
[[ -n "\${admin_network_uuid}" ]] || fatal "missing admin network UUID"
[[ -n "\${package}" ]] || fatal "missing package"
[[ -n "\${cns_resolvers}" ]] || fatal "missing CNS resolver"
[[ -n "\${binder_resolvers}" ]] || fatal "missing binder resolver"

# - user-script: Note that until TRITON-605 is resolved, net-agent will likely
#   be undoing our explicit "resolvers" below. As a workaround we'll have a
#   user-script that sorts it out on boot (see ./boot/configure.sh for a future
#   alternative to this user-script).
# - tags.smartdc_role: So 'sdc-login -l prom' works.
echo "Creating VM ${ALIAS} ..."
vm_uuid=\$((sdc-vmapi /vms?sync=true -X POST -d@/dev/stdin | json -H vm_uuid) <<PAYLOAD
{
    "alias": "${ALIAS}",
    "billing_id": "\${package}",
    "brand": "lx",
    "image_uuid": "${IMAGE_UUID}",
    "networks": [{"uuid": "\${admin_network_uuid}"}, {"uuid": "\${network_uuid}", "primary": true}],
    "owner_uuid": "\${admin_uuid}",
    "server_uuid": "\${headnode_uuid}",
    "resolvers": ["\$(echo "\${cns_resolvers},\${binder_resolvers},8.8.8.8" | sed -e 's/,/","/g')"],
    "customer_metadata": {
        "cnsResolvers": "\${cns_resolvers}",
        "user-script": "#!/bin/bash\n\nset -o errexit\nset -o pipefail\nset -o xtrace\n\nmdata-get cnsResolvers | tr , '\n' | while read ip; do\n        grep \"^nameserver \\\$ip$\" /etc/resolvconf/resolv.conf.d/head >/dev/null 2>&1 || echo \"nameserver \\\$ip\" >> /etc/resolvconf/resolv.conf.d/head;\n    done\nresolvconf -u\n\nexit 0\n"
    },
    "tags": {
        "smartdc_role": "prometheus"
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
prometheus_ip=\$(vmadm get \${vm_uuid} | json nics.1.ip)
cns_zone="\${prometheus_dc}.cns.\${prometheus_domain}"

cp prometheus.yml prometheus.yml.bak
cat >prometheus.yml <<PROMYML
# my global config
global:
  scrape_interval:     15s # Set the scrape interval to every 15 seconds. Default is every 1 minute.
  evaluation_interval: 15s # Evaluate rules every 15 seconds. The default is every 1 minute.
  # scrape_timeout is set to the global default (10s).

# Load rules once and periodically evaluate them according to the global 'evaluation_interval'.
rule_files:
  # - "first.rules"
  # - "second.rules"

# A scrape configuration containing exactly one endpoint to scrape:
# Here it's Prometheus itself.
scrape_configs:
  # The job name is added as a label 'job=<job_name>' to any timeseries scraped from this config.
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

echo ""
echo "* * * Successfully setup * * *"
echo "Prometheus: http://\${prometheus_ip}:9090/"
echo ""
echo "You can setup a grafana0 zone next via:"
echo "    ./setup-grafana.sh $HOST"

EOF
