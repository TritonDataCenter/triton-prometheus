#!/bin/bash
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# Copyright 2019 Joyent, Inc.
#

export PS4='[\D{%FT%TZ}] ${BASH_SOURCE}:${LINENO}: '\
'${FUNCNAME[0]:+${FUNCNAME[0]}(): }'

set -o errexit
set -o pipefail
set -o xtrace

#
# If the Prometheus instance is deployed as a Triton zone, /etc/resolv.conf
# will get overwritten with the zone's "resolvers" vm data on each boot. Thus,
# we must overwrite /etc/resolv.conf with localhost anew on each boot.
#

ROOT_DIR=/opt/triton/prometheus
CONF_DIR=${ROOT_DIR}/etc
CONFIG_JSON=${CONF_DIR}/config.json
DNS_DOMAIN=$(json -f "${CONFIG_JSON}" dns_domain)

#
# If the instance is deployed as a Manta zone, config-agent will take care of
# writing /etc/resolv.conf, so we can exit early here.
#
if [[ $(json 'is_manta_service' < "${CONFIG_JSON}") == 'true' ]]; then
    exit 0
fi

echo "search ${DNS_DOMAIN}" > /etc/resolv.conf.new
echo 'nameserver 127.0.0.1' >> /etc/resolv.conf.new

if ! diff /etc/resolv.conf /etc/resolv.conf.new > /dev/null; then
    echo 'Updating /etc/resolv.conf'
    cp /etc/resolv.conf /etc/resolv.conf.bak
    mv /etc/resolv.conf.new /etc/resolv.conf
else
   rm /etc/resolv.conf.new
fi

exit 0
