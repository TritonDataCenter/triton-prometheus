#!/bin/bash
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# Copyright (c) 2018, Joyent, Inc.
#

#
# One-time setup of a Triton prometheus core zone.
#
# It is expected that this is run via the standard Triton user-script,
# i.e. as part of the "mdata:execute" SMF service. That user-script ensures
# this setup.sh is run once for each (re)provision of the image. However
# script should also attempt to be idempotent.
#

export PS4='[\D{%FT%TZ}] ${BASH_SOURCE}:${LINENO}: ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'
set -o errexit
set -o pipefail
set -o xtrace

PATH=/opt/local/bin:/opt/local/sbin:/usr/bin:/usr/sbin

# Prometheus data is stored on its delegate dataset:
#
#   /data/prometheus/
#       data/    # TSDB database
#       etc/     # config file(s)
#       keys/    # keys with which to auth with CMON
#
PERSIST_DIR=/data/prometheus
DATA_DIR=$PERSIST_DIR/data
ETC_DIR=$PERSIST_DIR/etc
KEY_DIR=$PERSIST_DIR/keys

# Key file paths. Keep in sync with "bin/prometheus-configure".
# - PEM format private key
PRIV_KEY_FILE=$KEY_DIR/prometheus.id_rsa
# - SSH public key (to be added to admin)
PUB_KEY_FILE=$KEY_DIR/prometheus.id_rsa.pub
# - Public client cert file derived from the key.
CLIENT_CERT_FILE=$KEY_DIR/prometheus.cert.pem


# ---- internal routines

function fatal {
    printf '%s: ERROR: %s\n' "$(basename $0)" "$*" >&2
    exit 1
}


# Mount our delegated dataset at /data.
function prometheus_setup_delegate_dataset() {
    local data
    local mountpoint

    dataset=zones/$(zonename)/data
    mountpoint=$(zfs get -Hp mountpoint $dataset | awk '{print $3}')
    if [[ $mountpoint != "/data" ]]; then
        zfs set mountpoint=/data $dataset
    fi
}


# Setup key and client certificate used to auth with this DC's CMON.
#
# Dev Notes:
# - I'm not sure of the common name to use here. "admin" doesn't
#   seem correct.
# - Default to ecdsa? Supported for CMON auth?
function prometheus_setup_key() {
    local key_name

    if [[ -f "$CLIENT_CERT_FILE" && -f "$PRIV_KEY_FILE" && -f "$PUB_KEY_FILE" ]]; then
        echo "Key files already exist: $CLIENT_CERT_FILE, $PRIV_KEY_FILE, $PUB_KEY_FILE"
    else
        echo "Generating key and client cert for CMON auth"
        mkdir -p $KEY_DIR
        key_name=prometheus-$(zonename | cut -d- -f1)-$(date -u '+%Y%m%dT%H%M%S')
        ssh-keygen -t rsa -b 2048 -f $PRIV_KEY_FILE -N "" -C "$key_name"
        openssl req -new -key $PRIV_KEY_FILE -out /tmp/prometheus.csr.pem \
            -subj "/CN=admin"
        openssl x509 -req -days 365 -in /tmp/prometheus.csr.pem \
            -signkey $PRIV_KEY_FILE -out $CLIENT_CERT_FILE
    fi
}


function prometheus_setup_env {
    # Add 'promtool' to the PATH.
    echo "" >>/root/.profile
    echo "export PATH=/opt/triton/prometheus/prometheus:\$PATH" >>/root/.profile
}


function prometheus_setup_prometheus {
    local config_file
    local dc_name
    local dns_domain

    config_file=$ETC_DIR/prometheus.yml
    dc_name=$(mdata-get sdc:datacenter_name)
    dns_domain=$(mdata-get sdc:dns_domain)
    if [[ -z "$dns_domain" ]]; then
        # As of TRITON-92, we expect sdcadm to set this for all core Triton
        # zones.
        fatal "could not determine 'dns_domain'"
    fi

    mkdir -p $ETC_DIR
    mkdir -p $DATA_DIR

    #XXX this needed? Used for --web.external-url=http://\${prometheus_ip}:9090/
    #prometheus_ip=\$(vmadm get \${vm_uuid} | json nics.1.ip)

# TODO (START HERE):
# - Q: does output of that config-agent post_cmd script get in the config-agent
#   log? It would be nice.
# * * * then on to networking:
# - ...
# * * * then other stuff:
# - TLS and auth support (given that prom will be listening on the external
#   likely)
# - see key mgmt TODOs below
# - 'sdcadm up prometheus' support; I think this is done.


    # Generate Config
    cat >$config_file <<CONFIG
global:
  scrape_interval:     15s # Default is 1 minute.
  evaluation_interval: 15s # Default is 1 minute.
  # scrape_timeout is set to the global default (10s).

scrape_configs:
  # The job name is added as a label 'job=<job_name>' to any timeseries scraped
  # from this config.
  - job_name: 'admin_${dc_name}'
    scheme: https
    tls_config:
      cert_file: $CLIENT_CERT_FILE
      key_file: $PRIV_KEY_FILE
      insecure_skip_verify: true
    relabel_configs:
      - source_labels: [__meta_triton_machine_alias]
        target_label: instance
    triton_sd_configs:
      - account: 'admin'
        dns_suffix: 'cmon.$dc_name.cns.$dns_domain'
        endpoint: 'cmon.$dc_name.cns.$dns_domain'
        version: 1
        tls_config:
          cert_file: $CLIENT_CERT_FILE
          key_file: $PRIV_KEY_FILE
          insecure_skip_verify: true
CONFIG

    /usr/sbin/svccfg import /opt/triton/prometheus/smf/manifests/prometheus.xml
}


# ---- mainline

# We do this before common setup in case we later have a config-agent-written
# config file that will live under /data.
prometheus_setup_delegate_dataset

CONFIG_AGENT_LOCAL_MANIFESTS_DIRS=/opt/triton/prometheus
source /opt/smartdc/boot/lib/util.sh
sdc_common_setup

# TODO:
# - where to add this key to the 'admin' user?
# - for scaling/sharding prom: share this certificate key between prom zones?
#   TODO: mdata-put it here and 'sdcadm post-setup' can pick it up
#   TODO: have something in prom zone that can spit out whether this is
#       configured properly? E.g. the imgapi-status script or something will
#       complain if doesn't have appropriate access. This could check UFDS
#       or mahi if has this key.
#   TODO: ticket for key rotation of this key
#   TODO: chown nobody needed eventually for these /data files?
prometheus_setup_key

prometheus_setup_env
prometheus_setup_prometheus

# Log rotation.
sdc_log_rotation_add config-agent /var/svc/log/*config-agent*.log 1g
sdc_log_rotation_add registrar /var/svc/log/*registrar*.log 1g
sdc_log_rotation_add prometheus /var/svc/log/*prometheus*.log 1g
sdc_log_rotation_setup_end

sdc_setup_complete

exit 0
