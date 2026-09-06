#!/bin/sh
set -eu

if [ "$#" -eq 2 ] && [ "$1" = -q ] && [ "$2" = net.ipv4.conf.all.src_valid_mark=1 ]; then
    [ "$(cat /proc/sys/net/ipv4/conf/all/src_valid_mark)" = 1 ]
    exit
fi

exec /usr/sbin/sysctl "$@"
