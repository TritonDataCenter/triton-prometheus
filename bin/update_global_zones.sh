#!/bin/bash
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# Copyright (c) 2019, Joyent, Inc.
#

#
# This generates the global_zones.json file that's used by prometheus with the
# files_sd service discovery in order that new CNs will automatically be
# discovered by the config.
#

set -o errexit
set -o pipefail

ROOT_DIR=/opt/triton/prometheus
CMON_AUTH_DIR=${ROOT_DIR}/keys
CMON_KEY_FILE=${CMON_AUTH_DIR}/prometheus.key.pem
CMON_CERT_FILE=${CMON_AUTH_DIR}/prometheus.cert.pem
CONF_DIR=${ROOT_DIR}/etc
OUTPUT_FILE=${CONF_DIR}/global_zones.json
OUTPUT_FILE_TMP=${OUTPUT_FILE}.tmp.$$
CONFIG_JSON=${CONF_DIR}/config.json
DATACENTER_NAME=$(json -f "${CONFIG_JSON}" datacenter)
DNS_DOMAIN=$(json -f "${CONFIG_JSON}" dns_domain)
CMON_HOST="cmon.${DATACENTER_NAME}.cns.${DNS_DOMAIN}"

function cleanup {
    exit_code=$?
    if [[ ${exit_code} -ne 0 ]]; then
        echo "Failed to update global_zones.json: code ${exit_code}" >&2
    fi
    rm -f ${OUTPUT_FILE_TMP}
}
trap cleanup EXIT


echo "[$(date -u)] Updating global_zones.json"

curl -sS -k --max-time 120 \
    -E ${CMON_CERT_FILE} \
    --key ${CMON_KEY_FILE} \
    https://${CMON_HOST}:9163/v1/gz/discover \
    | json cns \
    | json -e "this.targets=[this.server_uuid+'.cmon.blackstump.cns.joyent.us:9163']; this.server_uuid=undefined; this.labels={'job': 'global_zones_${DATACENTER_NAME}'}" \
    > ${OUTPUT_FILE_TMP}

# If there was an error we'll go to cleanup() thanks to errexit & pipefail

chown nobody:nobody ${OUTPUT_FILE_TMP}
mv ${OUTPUT_FILE_TMP} ${OUTPUT_FILE}
echo "Found $(json -f ${OUTPUT_FILE} length) GZs"

exit 0
