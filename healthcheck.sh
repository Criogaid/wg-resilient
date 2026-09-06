#!/bin/sh
set -eu
wg show "${WG_INTERFACE:-wg0}" >/dev/null
kill -0 "$(cat /run/udp2raw.pid)"
if [ "${SPEEDER_ENABLED:-false}" = true ]; then
    kill -0 "$(cat /run/speederv2.pid)"
fi
