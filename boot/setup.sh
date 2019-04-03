#!/bin/bash
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# Copyright (c) 2019, Joyent, Inc.
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

NODE=/opt/triton/prometheus/build/node/bin/node

ROOT_DIR=/opt/triton/prometheus
CONFIG_JSON=$ROOT_DIR/etc/config.json

#
# CMON key-related paths. Keep in sync with "bin/certgen" and
# "bin/prometheus-configure".
#
CMON_AUTH_DIR=$ROOT_DIR/keys
CMON_KEY_FILE=$CMON_AUTH_DIR/prometheus.key.pem
CMON_CERT_FILE=$CMON_AUTH_DIR/prometheus.cert.pem

#
# Prometheus data that should be persistent across reprovisions is stored on its
# delegate dataset:
#
#   /data/prometheus/
#       data/    # time-series database
#
PERSIST_DIR=/data/prometheus
DATA_DIR=$PERSIST_DIR/data

function fatal {
    printf '%s: ERROR: %s\n' "$(basename $0)" "$*" >&2
    exit 1
}

#
# We can't use the sapi config file to determine $FLAVOR yet, because this runs
# before the SAPI config gets written on zone setup, so we check for the
# existence of manta_role instead. This is the same method that moray uses for
# determining $FLAVOR.
#
if [[ -n $(mdata-get sdc:tags.manta_role) ]]; then
    fatal "Deploying Prometheus as a Manta service is not yet supported."
    export FLAVOR="manta"
else
    export FLAVOR="sdc"
fi

# ---- internal routines

# Mount our delegate dataset at /data.
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
    mkdir -p $DATA_DIR

    /usr/sbin/svccfg import /opt/triton/prometheus/smf/manifests/prometheus.xml

    #
    # Set up key and client certificate used to auth with this DC's CMON.
    #
    echo "Generating key and client cert for CMON auth"
    mkdir -p $CMON_AUTH_DIR
    ${NODE} "--abort_on_uncaught_exception" \
        /opt/triton/prometheus/bin/certgen $FLAVOR

    #
    # The prometheus SMF service runs as the 'nobody' user, so the files it
    # accesses must be owned by nobody. Here, we ensure this for the files and
    # directory that will remain static for the lifetime of the zone.
    #
    chown nobody:nobody \
        $CMON_KEY_FILE \
        $CMON_CERT_FILE \
        $DATA_DIR \

    #
    # prometheus-configure contains the common setup code that must be run here
    # and also on config-agent updates
    #
    TRACE=1 /opt/triton/prometheus/bin/prometheus-configure
}

# ---- mainline

prometheus_setup_delegate_dataset
prometheus_setup_env

if [[ "$FLAVOR" == "manta" ]]; then

    MANTA_SCRIPTS_DIR=/opt/smartdc/boot/manta-scripts
    source ${MANTA_SCRIPTS_DIR}/util.sh
    source ${MANTA_SCRIPTS_DIR}/services.sh

    manta_common_presetup
    manta_add_manifest_dir "/opt/triton/prometheus"
    manta_common_setup "prometheus" 0

    prometheus_setup_prometheus

    manta_common_setup_end

else # "$FLAVOR" == "sdc"

    CONFIG_AGENT_LOCAL_MANIFESTS_DIRS=/opt/triton/prometheus
    source /opt/smartdc/boot/lib/util.sh
    sdc_common_setup

    prometheus_setup_prometheus

    # Log rotation.
    sdc_log_rotation_add config-agent /var/svc/log/*config-agent*.log 1g
    sdc_log_rotation_add registrar /var/svc/log/*registrar*.log 1g
    sdc_log_rotation_add prometheus /var/svc/log/*prometheus*.log 1g
    sdc_log_rotation_setup_end

    sdc_setup_complete
fi

exit 0
