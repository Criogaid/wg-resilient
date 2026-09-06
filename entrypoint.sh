#!/usr/bin/env bash
set -Eeuo pipefail

WG_SOURCE_CONFIG=/config/wg0.conf
WG_INTERFACE=${WG_INTERFACE:-wg0}
WG_CONFIG=
UDP2RAW_PORT=${UDP2RAW_PORT:-4096}
WG_LISTEN_PORT=51820
WG_TUNNEL_PORT=51821
SPEEDER_RELAY_PORT=51822
SPEEDER_ENABLED=${SPEEDER_ENABLED:-false}
SPEEDER_FEC=${SPEEDER_FEC:-20:10}
SPEEDER_MODE=0
SPEEDER_MTU=${SPEEDER_MTU:-1250}
SPEEDER_TIMEOUT=${SPEEDER_TIMEOUT:-8}
UDP2RAW_MODE=faketcp
UDP2RAW_CIPHER=aes128cbc
UDP2RAW_AUTH=hmac_sha1

raw_pid=
speeder_pid=
wg_up=false
route_ip=
stopping=false

log() { printf '[wg-resilient] %s\n' "$*"; }
die() { log "error: $*" >&2; exit 1; }

read_secret() {
    local value=${UDP2RAW_PASSWORD:-}
    if [[ -n ${UDP2RAW_PASSWORD_FILE:-} ]]; then
        [[ -r $UDP2RAW_PASSWORD_FILE ]] || die "cannot read UDP2RAW_PASSWORD_FILE"
        value=$(<"$UDP2RAW_PASSWORD_FILE")
    fi
    [[ -n $value ]] || die "set UDP2RAW_PASSWORD or UDP2RAW_PASSWORD_FILE"
    [[ $value =~ ^[A-Za-z0-9._~+-]+$ ]] || die "udp2raw password contains unsupported characters"
    printf '%s' "$value"
}

cleanup() {
    local status=$?
    $stopping && return
    stopping=true
    trap - EXIT TERM INT
    [[ -z $raw_pid ]] || kill "$raw_pid" 2>/dev/null || true
    [[ -z $speeder_pid ]] || kill "$speeder_pid" 2>/dev/null || true
    [[ -z $raw_pid ]] || wait "$raw_pid" 2>/dev/null || true
    [[ -z $speeder_pid ]] || wait "$speeder_pid" 2>/dev/null || true
    $wg_up && wg-quick down "$WG_CONFIG" >/dev/null 2>&1 || true
    [[ -z $WG_CONFIG ]] || rm -f -- "$WG_CONFIG"
    exit "$status"
}

trap cleanup EXIT
trap 'exit 0' TERM INT

[[ ${ROLE:-} == server || ${ROLE:-} == client ]] || die "ROLE must be server or client"
[[ $WG_INTERFACE =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,14}$ ]] || die "WG_INTERFACE must be 1-15 letters, digits, underscores, dots or hyphens, starting with a letter or digit"
[[ -f $WG_SOURCE_CONFIG && -r $WG_SOURCE_CONFIG ]] || die "WireGuard config must be a readable file: $WG_SOURCE_CONFIG"
if ip link show dev "$WG_INTERFACE" >/dev/null 2>&1; then
    die "interface already exists: $WG_INTERFACE (choose another WG_INTERFACE or stop its owner)"
fi
awk -F= '
    /^[[:space:]]*AllowedIPs[[:space:]]*=/ {
        sub(/#.*/, "", $2); gsub(/[[:space:]]/, "", $2)
        n=split($2, routes, ",")
        for (i=1; i<=n; i++) if (routes[i] == "0.0.0.0/0" || routes[i] == "::/0") exit 1
    }' "$WG_SOURCE_CONFIG" || die "default routes are not supported in host mode; use the peer tunnel subnet in AllowedIPs"
[[ $SPEEDER_ENABLED == true || $SPEEDER_ENABLED == false ]] || die "SPEEDER_ENABLED must be true or false"
password=$(read_secret)
umask 077
mkdir -p /run/wireguard
chmod 700 /run/wireguard
WG_CONFIG=/run/wireguard/$WG_INTERFACE.conf
cp -- "$WG_SOURCE_CONFIG" "$WG_CONFIG"
chmod 600 "$WG_CONFIG"
raw_config=/run/udp2raw.conf

if [[ $ROLE == client ]]; then
    [[ -n ${UDP2RAW_REMOTE_HOST:-} ]] || die "client requires UDP2RAW_REMOTE_HOST"
    route_ip=$(getent ahostsv4 "$UDP2RAW_REMOTE_HOST" | awk 'NR == 1 { print $1 }')
    [[ -n $route_ip ]] || die "cannot resolve IPv4 address for $UDP2RAW_REMOTE_HOST"
    raw_listen_port=$WG_TUNNEL_PORT
    $SPEEDER_ENABLED && raw_listen_port=$SPEEDER_RELAY_PORT
    cat >"$raw_config" <<EOF
-c
-l 127.0.0.1:${raw_listen_port}
-r ${route_ip}:${UDP2RAW_PORT}
EOF
else
    raw_remote_port=$WG_LISTEN_PORT
    $SPEEDER_ENABLED && raw_remote_port=$SPEEDER_RELAY_PORT
    cat >"$raw_config" <<EOF
-s
-l 0.0.0.0:${UDP2RAW_PORT}
-r 127.0.0.1:${raw_remote_port}
EOF
fi

cat >>"$raw_config" <<EOF
-k ${password}
--raw-mode ${UDP2RAW_MODE}
--cipher-mode ${UDP2RAW_CIPHER}
--auth-mode ${UDP2RAW_AUTH}
-a
--disable-color
EOF

wg-quick up "$WG_CONFIG"
wg_up=true

if $SPEEDER_ENABLED; then
    if [[ $ROLE == client ]]; then
        speederv2 -c -l"127.0.0.1:${WG_TUNNEL_PORT}" -r"127.0.0.1:${SPEEDER_RELAY_PORT}" \
            -f"$SPEEDER_FEC" --mode "$SPEEDER_MODE" --mtu "$SPEEDER_MTU" \
            --timeout "$SPEEDER_TIMEOUT" -k "$password" --disable-color &
    else
        speederv2 -s -l"127.0.0.1:${SPEEDER_RELAY_PORT}" -r"127.0.0.1:${WG_LISTEN_PORT}" \
            -f"$SPEEDER_FEC" --mode "$SPEEDER_MODE" --mtu "$SPEEDER_MTU" \
            --timeout "$SPEEDER_TIMEOUT" -k "$password" --disable-color &
    fi
    speeder_pid=$!
    printf '%s\n' "$speeder_pid" >/run/speederv2.pid
fi

udp2raw --conf-file "$raw_config" &
raw_pid=$!
printf '%s\n' "$raw_pid" >/run/udp2raw.pid
log "$ROLE started (interface: $WG_INTERFACE, UDPspeeder: $SPEEDER_ENABLED)"

set +e
if [[ -n $speeder_pid ]]; then
    wait -n "$raw_pid" "$speeder_pid"
else
    wait "$raw_pid"
fi
status=$?
set -e
exit "$status"
