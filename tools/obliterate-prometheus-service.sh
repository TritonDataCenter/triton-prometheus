#!/bin/bash
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# Copyright (c) 2019 Joyent, Inc.
#

#
# Obliterate a Triton prometheus service and instances. This is just for
# development.
#
# Usage:
#       scp tools/obliterate-prometheus-service.sh coal:/var/tmp
#       ssh coal
#       /var/tmp/obliterate-prometheus-service.sh
#

if [[ -n "$TRACE" ]]; then
    export PS4='[\D{%FT%TZ}] ${BASH_SOURCE}:${LINENO}: ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'
    set -o xtrace
fi
set -o errexit
set -o pipefail

function fatal() {
    echo "$0: fatal: \$*" >&2
    exit 1
}

function obliterate_prometheus_service {
    local promSvc

    promSvc=$(sdc-sapi /services?name=prometheus | json -H 0.uuid)
    if [[ -z $promSvc ]]; then
        return
    fi

    sdc-sapi /instances?service_uuid=$promSvc \
        | json -Ha uuid params.alias \
        | while read uuid alias; do
            echo "Delete prometheus instance $uuid ($alias)"
            sdc-sapi /instances/$uuid -X DELETE
        done

    echo "Delete prometheus service ($promSvc)"
    sdc-sapi /services/$promSvc -X DELETE
}


# ---- mainline

# Guard from running this in production. This is the same guard file we use
# for running many of the Triton test suites.
if [[ ! -f "/lib/sdc/.sdc-test-no-production-data" ]]; then
    cat <<EOF
To run this you must create the following file:

    /lib/sdc/.sdc-test-no-production-data

after ensuring you have no production data in this TritonDC.
EOF
    exit 2
fi


obliterate_prometheus_service