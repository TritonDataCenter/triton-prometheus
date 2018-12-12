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
# this setup.sh is run once for each (re)provision of the image. However this
# script should also be idempotent.
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

# Keep in sync with "bin/certgen"
ROOT_PRIV_KEY_PATH='/root/.ssh/sdc.id_rsa'

SAPI_INST_DATA_JSON=$ETC_DIR/sapi-inst-data.json

# ---- internal routines

function fatal {
    printf '%s: ERROR: %s\n' "$(basename $0)" "$*" >&2
    exit 1
}


# Mount our delegated dataset at /data.
function prometheus_setup_delegate_dataset {
    local data
    local mountpoint

    dataset=zones/$(zonename)/data
    mountpoint=$(zfs get -Hp mountpoint $dataset | awk '{print $3}')
    if [[ $mountpoint != "/data" ]]; then
        zfs set mountpoint=/data $dataset
    fi
}


function prometheus_setup_env {
    if ! grep prometheus /root/.profile >/dev/null; then
        echo "" >>/root/.profile
        echo "export PATH=/opt/triton/prometheus/bin:/opt/triton/prometheus/prometheus:\$PATH" >>/root/.profile
    fi
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

    # This is disabled by default. It is up to 'prometheus-configure' to
    # enable it.
    /usr/sbin/svccfg import /opt/triton/prometheus/smf/manifests/prometheus.xml

    # 'prometheus-configure' is typically run by config-agent via the template
    # 'post_cmd' (for first-time zone setup and for config changes). However,
    # this file is on the delegate dataset, so for reprovisions config-agent
    # might not have a change to make, and thus we should run the configure script
    # manually in this case.
    if [[ -f $SAPI_INST_DATA_JSON && -f $ROOT_PRIV_KEY_PATH ]]; then
        TRACE=1 /opt/triton/prometheus/bin/prometheus-configure
    fi

    return 0
}

# ---- mainline

prometheus_setup_delegate_dataset
prometheus_setup_env

# Before 'sdc_common_setup' so the prometheus SMF service is imported before
# config-agent is first setup.
prometheus_setup_prometheus

CONFIG_AGENT_LOCAL_MANIFESTS_DIRS=/opt/triton/prometheus
source /opt/smartdc/boot/lib/util.sh
sdc_common_setup

# Log rotation.
sdc_log_rotation_add config-agent /var/svc/log/*config-agent*.log 1g
sdc_log_rotation_add registrar /var/svc/log/*registrar*.log 1g
sdc_log_rotation_add prometheus /var/svc/log/*prometheus*.log 1g
sdc_log_rotation_setup_end

sdc_setup_complete

exit 0
