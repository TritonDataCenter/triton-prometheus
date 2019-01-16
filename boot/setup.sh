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


# ---- internal routines

function fatal {
    printf '%s: ERROR: %s\n' "$(basename $0)" "$*" >&2
    exit 1
}


# Mount our delegated dataset at /data.
function prometheus_setup_dirs {
    local data
    local mountpoint

    dataset=zones/$(zonename)/data
    mountpoint=$(zfs get -Hp mountpoint $dataset | awk '{print $3}')
    if [[ $mountpoint != "/data" ]]; then
        zfs set mountpoint=/data $dataset
    fi

    mkdir -p $ETC_DIR
    mkdir -p $DATA_DIR
}


function prometheus_setup_env {
    if ! grep prometheus /root/.profile >/dev/null; then
        echo "" >>/root/.profile
        echo "export PATH=/opt/triton/prometheus/bin:/opt/triton/prometheus/prometheus:\$PATH" >>/root/.profile
    fi
}


# ---- mainline

prometheus_setup_dirs
prometheus_setup_env

CONFIG_AGENT_LOCAL_MANIFESTS_DIRS=/opt/triton/prometheus
source /opt/smartdc/boot/lib/util.sh
sdc_common_setup


# Ensure 'prometheus-configure' ran and ran successfully.
#
# 'prometheus-configure' is responsible for writing the Prometheus config and
# getting the "prometheus" SMF service up and running. SAPI instance config
# changes can mean Prometheus needs to be reconfigured, so config-agent is
# set (via sapi_manifests/prometheus/manifest.json) to run
# 'prometheus-configure'. However, there are some cases where we need to
# manually run it here or check on that it ran successfully:
#
# 1. Currently at least, a synchronous run of config-agent, as is done by
#    'sdc_common_setup', does *not* fail if the template's 'post_cmd' fails.
#    We want a failure there to result in this setup.sh failing.
# 2. Because the config files in question live on the delegate dataset, it
#    is possible that during a *re*-provision of this zone, config-agent
#    will not run its 'post_cmd'.  We still need 'prometheus-configure' to
#    run for a reprovision.
if ! svcs -Ho state prometheus 2>/dev/null; then
    # Either 'prometheus-configure' hasn't run, or it failed early.
    TRACE=1 /opt/triton/prometheus/bin/prometheus-configure
else
    currState=$(svcs -Ho state prometheus)
    if [[ "$currState" != "online" ]]; then
        # 'prometheus-configure' must have failed. Let's run it again to get
        # trace output and (we hope) show the error that was hit.
        echo "The prometheus SMF service is not online: '$currState'." \
            "Did config-agent's run of 'prometheus-configure' fail? Re-running"
        TRACE=1 /opt/triton/prometheus/bin/prometheus-configure
    fi
fi


# Log rotation.
sdc_log_rotation_add config-agent /var/svc/log/*config-agent*.log 1g
sdc_log_rotation_add registrar /var/svc/log/*registrar*.log 1g
sdc_log_rotation_add prometheus /var/svc/log/*prometheus*.log 1g
sdc_log_rotation_setup_end

sdc_setup_complete

exit 0
