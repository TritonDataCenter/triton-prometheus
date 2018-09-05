#!/bin/bash
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# Copyright (c) 2018, Joyent, Inc.
#

export PS4='[\D{%FT%TZ}] ${BASH_SOURCE}:${LINENO}: ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'
set -o errexit
set -o pipefail
set -o xtrace

# Ensure 'cnsResolvers' IPs get in our resolv.conf for prometheus discovery.
# This is only necessary because we can't use 'vm.resolvers' because TRITON-605.
mdata-get cnsResolvers \
    | sed -e 's/,/\n/' \
    | while read ip; do
        grep "^nameserver $ip$" /etc/resolvconf/resolv.conf.d/head >/dev/null 2>&1 \
            || echo "nameserver $ip" >> /etc/resolvconf/resolv.conf.d/head;
    done
resolvconf -u

exit 0
