#!/bin/bash
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# Copyright (c) 2018 Joyent, Inc.
#

#
# This tool works to set up prometheus (and required cmon/cns bits) on an LX
# zone in a production environment. From the global zone, run
# ./setup-prometheus.sh as root.
#
# You should be able to then go to the prometheus page that gets spit out at
# the end. It takes a few minutes for the discovery process to complete
# before you'll see any metrics.
#

IMAGE_UUID="7b5981c4-1889-11e7-b4c5-3f3bdfc9b88b" # LX Ubuntu 16.04
PACKAGE_UUID="4769a8f9-de51-4c1e-885f-c3920cc68137" # sdc_1024
PROMETHEUS_VERSION="2.3.2"
ALIAS=prometheus0

function usage {
    echo "usage: ./setup-prometheus.sh [-i] [-f] [-r '<extra resolver 1>,<extra resolver 2>'] [-s <non-local server uuid>] [-k <path to ssh key>]" >&2
    exit 1
}

function fatal() {
    echo "FATAL: $*" >&2
    exit 1
}

# Necessary to ensure compatibility for servers with LACP - see HEAD-2247
function get_admin_ip() {
    sysinfo | /usr/node/bin/node -e "
    function _getAdminIpSysinfo(sysinfo_object, callback) {
        var admin_tag = 'admin';
        var interfaces = sysinfo_object['Network Interfaces'];
        var adminifaces;

        if (sysinfo_object['Admin NIC Tag']) {
            admin_tag = sysinfo_object['Admin NIC Tag'];
        }

        adminifaces = Object.keys(interfaces).filter(function (iface) {
            return interfaces[iface]['NIC Names'].indexOf(admin_tag) !== -1;
        });

        if (adminifaces && adminifaces.length !== 0) {
            callback(null, interfaces[adminifaces[0]]['ip4addr']);
            return;
        }

        callback(new Error('No admin NIC found with tag ' +
            admin_tag + ' in compute node sysinfo'));
    }

    var chunks = [];
    process.stdin.on('data', function (chunk) { chunks.push(chunk) });
    process.stdin.on('close', function () {
        var sysinfo = JSON.parse(chunks.join(''));
        _getAdminIpSysinfo(sysinfo, function (err, adminIp) {
            if (err) {
                throw err;
            } else {
                console.log(adminIp);
            }
        });
    });
    "
}

insecure_flag="false"
firewall_flag="false"
ssh_key_file=
ssh_key=
resolvers=
server_uuid=$(sysinfo | json UUID) # local headnode by default
while getopts ":ifr:s:k:" f; do
    case $f in
        i)  insecure_flag="true"
            ;;
        f)  firewall_flag="true"
            ;;
        r)  resolvers=$(echo $OPTARG | tr -d "\n\t\r ")
            ;;
        s)  server_uuid=$OPTARG
            ;;
        k)  ssh_key_file=$OPTARG
            ;;
        \?) usage
            ;;
    esac
done

if [[ $# -gt 8 ]]; then
    usage
fi

set -o errexit
set -o pipefail

if [[ -n "${TRACE}" ]]; then
    set -o xtrace
fi

if [[ -z ${SSH_OPTS} ]]; then
    SSH_OPTS=""
fi

. ~/.bash_profile

# Check that key exists if we passed the flag; then read the key's contents
if [[ -n "${ssh_key_file}" ]]; then
    [[ -f "${ssh_key_file}" ]] || fatal "ssh key not found at ${ssh_key_file}"
    ssh_key=$(<"${ssh_key_file}")
fi

#
# prometheus0 zone creation
#
admin_uuid=$(sdc-useradm get admin | json uuid)

[[ -n $(sdc-server lookup uuid=${server_uuid}) ]] || fatal "Invalid server UUID"

vm_uuid=$(sdc-vmadm list alias=$ALIAS owner_uuid=${admin_uuid} -H -o uuid)
[[ -z "$vm_uuid" ]] || fatal "VM $ALIAS already exists"

if ! sdc-imgadm get ${IMAGE_UUID} >/dev/null 2>&1; then
    echo "Image ${IMAGE_UUID} not found: importing now; must delete in event of rollback"
    sdc-imgadm import -S https://images.joyent.com ${IMAGE_UUID} </dev/null
fi

# Setup for CNS to actually work
cns_enabled=$(sdc-useradm get admin | json triton_cns_enabled)
echo "For admin user, existing value of triton_cns_enabled = $cns_enabled"
if [[ $cns_enabled = 'false' ]]; then
    sdc-useradm replace-attr admin triton_cns_enabled true </dev/null
fi

network_uuid=$(sdc-vmadm get $(sdc-vmadm list alias=cmon owner_uuid=${admin_uuid} -H -o uuid | head -1) | json nics | json -ac 'nic_tag != "admin"' | json network_uuid)
admin_network_uuid=$(sdc-napi /networks?name=admin | json -H 0.uuid)

# Find package
[[ -n $(sdc-papi /packages | json -Ha uuid | grep $PACKAGE_UUID) ]] || fatal "missing package"

prometheus_dc=$(bash /lib/sdc/config.sh -json | json datacenter_name)
prometheus_domain=$(bash /lib/sdc/config.sh -json | json dns_domain)

echo "Admin account: ${admin_uuid}"
echo "Admin network: ${admin_network_uuid}"
echo "Server: ${server_uuid}"
echo "Network: ${network_uuid}"
echo "Alias: ${ALIAS}"

[[ -n "${admin_uuid}" ]] || fatal "missing admin UUID"
[[ -n "${network_uuid}" ]] || fatal "missing CMON network UUID"
[[ -n "${admin_network_uuid}" ]] || fatal "missing admin network UUID"

# - user-script: Note that until TRITON-605 is resolved, net-agent will likely
#   be undoing our explicit "resolvers" below. As a workaround we'll have a
#   user-script that sorts it out on boot (see ./boot/configure.sh for a future
#   alternative to this user-script).
# - tags.smartdc_role: So 'sdc-login -l prom' works.
echo "Creating VM ${ALIAS} ..."
vm_uuid=$((sdc-vmapi /vms?sync=true -X POST -d@/dev/stdin | json -H vm_uuid) <<PAYLOAD
{
    "alias": "${ALIAS}",
    "billing_id": "${PACKAGE_UUID}",
    "brand": "lx",
    "image_uuid": "${IMAGE_UUID}",
    "networks": [{"uuid": "${admin_network_uuid}"}, {"uuid": "${network_uuid}", "primary": true}],
    "firewall_enabled": ${firewall_flag},
    "owner_uuid": "${admin_uuid}",
    "server_uuid": "${server_uuid}",
    $(if [[ -n ${resolvers} ]]; then echo "\"resolvers\":[\"$(echo "${resolvers}" | sed -e 's/,/","/g')\"],"; fi)
    "customer_metadata": {
        "resolvers": "${resolvers}",
        "user-script": "#!/bin/bash\n\nset -o errexit\nset -o pipefail\nset -o xtrace\n\nmdata-get resolvers | tr , '\n' | while read ip; do\ngrep \"^nameserver \$ip\" /etc/resolvconf/resolv.conf.d/head >/dev/null 2>&1 || [[ -z \$ip ]] || echo \"nameserver \$ip\" >> /etc/resolvconf/resolv.conf.d/head;\n    done\nresolvconf -u\n\nexit 0\n"
    },
    "tags": {
        "smartdc_role": "prometheus"
    }
}
PAYLOAD
)

#
# Prometheus setup.
#

prometheus_ip=$(sdc-vmadm get ${vm_uuid} | json nics.1.ip)
server_ip=$(get_admin_ip)

# Find proper suffix for cmon zone
cns_url="cns.${prometheus_dc}.${prometheus_domain}"
owner_uuid=$(sdc-useradm get admin | json uuid)
cns_result=$(curl -s -X POST -H "Content-Type: application/json" $cns_url/suffixes-for-vm -d @- << JSON
{
    "owner_uuid": "${owner_uuid}",
    "networks": [
        "${network_uuid}"
    ]
}
JSON
)
cmon_zone="cmon.$(echo $cns_result | json suffixes.0 | cut -d. -f3-)"

# Generate and register key
key_name="${ALIAS}_key_$(date -u +%FT%TZ)"
ssh-keygen -t ecdsa -f prometheus_key -C "$key_name" -N ''
/opt/smartdc/bin/sdc-useradm add-key -n "$key_name" -f admin prometheus_key.pub
# Save priv key to transfer to prom vm; delete both keys
pub_key_contents=$(<prometheus_key.pub)
priv_key_contents=$(<prometheus_key)
rm prometheus_key.pub
rm prometheus_key

# Download prometheus into the zone
ssh ${SSH_OPTS} ${server_ip} <<SERVER
cd /zones/${vm_uuid}/root/root

# Download prometheus tarball
curl -L -kO https://github.com/prometheus/prometheus/releases/download/v${PROMETHEUS_VERSION}/prometheus-${PROMETHEUS_VERSION}.linux-amd64.tar.gz
tar -zxvf prometheus-${PROMETHEUS_VERSION}.linux-amd64.tar.gz
ln -s prometheus-${PROMETHEUS_VERSION}.linux-amd64 prometheus
cd prometheus

# Generate Cert
echo "${priv_key_contents}" > prometheus_key.priv.pem
openssl req -new -key prometheus_key.priv.pem -out prometheus_key.pub.pem -subj "/CN=admin" -days 3650 -nodes -x509

cp prometheus.yml prometheus.yml.bak

# Generate Config
cat >prometheus.yml <<PROMYML
global:
  scrape_interval:     15s # Set the scrape interval to every 15 seconds. Default is every 1 minute.
  evaluation_interval: 15s # Evaluate rules every 15 seconds. The default is every 1 minute.
  # scrape_timeout is set to the global default (10s).

rule_files:

# Scrape configuration including cmon
scrape_configs:
  # The job name is added as a label 'job=<job_name>' to any timeseries scraped from this config.
  - job_name: 'admin_${prometheus_dc}'
    scheme: https
    tls_config:
      cert_file: /root/prometheus/prometheus_key.pub.pem
      key_file: /root/prometheus/prometheus_key.priv.pem
      insecure_skip_verify: ${insecure_flag}
    relabel_configs:
      - source_labels: [__meta_triton_machine_alias]
        target_label: alias
      - source_labels: [__meta_triton_machine_id]
        target_label: instance
    triton_sd_configs:
      - account: 'admin'
        dns_suffix: '${cmon_zone}'
        endpoint: '${cmon_zone}'
        version: 1
        tls_config:
          cert_file: /root/prometheus/prometheus_key.pub.pem
          key_file: /root/prometheus/prometheus_key.priv.pem
          insecure_skip_verify: ${insecure_flag}
PROMYML

# Generate systemd manifest
cat > /zones/${vm_uuid}/root/etc/systemd/system/prometheus.service <<SYSTEMD
[Unit]
    Description=Prometheus server
    After=network.target

[Service]
    WorkingDirectory=/root/prometheus
    StandardOutput=syslog
    ExecStart=/root/prometheus/prometheus \\
        --storage.tsdb.path=/root/prometheus/data \\
        --config.file=/root/prometheus/prometheus.yml \\
        --web.external-url=http://${prometheus_ip}:9090/
    User=root

[Install]
    WantedBy=multi-user.target
SYSTEMD

# Add ssh key, if specified
if [[ -n "${ssh_key_file}" ]]; then
    echo "${ssh_key}" >> /zones/${vm_uuid}/root/root/.ssh/authorized_keys
fi

zlogin ${vm_uuid} "systemctl daemon-reload && systemctl enable prometheus && systemctl start prometheus && systemctl status prometheus" < /dev/null
SERVER

echo ""
echo "* * * Successfully setup * * *"
echo "Prometheus: http://${prometheus_ip}:9090/"
echo ""
echo "You can setup a grafana0 zone next via:"
echo "    ./setup-grafana-prod.sh [<non-local server uuid>]"
