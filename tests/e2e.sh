#!/bin/sh
set -eu

image=${IMAGE:-wg-resilient:local}
speeder=${SPEEDER_ENABLED:-false}
suffix=$$
network=wg-udp2raw-test-$suffix
server=wg-udp2raw-server-$suffix
client=wg-udp2raw-client-$suffix
tmp=$(mktemp -d "$(pwd)/.e2e.XXXXXX")

cleanup() {
    status=$?
    docker rm -f "$client" "$server" >/dev/null 2>&1 || true
    docker network rm "$network" >/dev/null 2>&1 || true
    rm -rf "$tmp"
    exit "$status"
}
trap cleanup EXIT INT TERM

server_private=$(docker run --rm --entrypoint wg "$image" genkey)
server_public=$(printf '%s' "$server_private" | docker run --rm -i --entrypoint wg "$image" pubkey)
client_private=$(docker run --rm --entrypoint wg "$image" genkey)
client_public=$(printf '%s' "$client_private" | docker run --rm -i --entrypoint wg "$image" pubkey)

cat >"$tmp/server.conf" <<EOF
[Interface]
Address = 10.77.0.1/24
MTU = 1280
ListenPort = 51820
PrivateKey = $server_private

[Peer]
PublicKey = $client_public
AllowedIPs = 10.77.0.2/32
EOF

cat >"$tmp/client.conf" <<EOF
[Interface]
Address = 10.77.0.2/24
MTU = 1280
PrivateKey = $client_private

[Peer]
PublicKey = $server_public
Endpoint = 127.0.0.1:51821
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 2
EOF

chmod 600 "$tmp/server.conf" "$tmp/client.conf"
printf '%s' test-password >"$tmp/password"
chmod 600 "$tmp/password"
for secret in '' /run/secrets/missing; do
    if docker run --rm -e ROLE=server -e UDP2RAW_PASSWORD_FILE="$secret" \
        -v "$tmp/server.conf:/config/wg0.conf:ro" "$image" >"$tmp/rejection.log" 2>&1; then
        echo 'missing credentials unexpectedly accepted' >&2
        exit 1
    fi
    grep -Eq 'set UDP2RAW_PASSWORD|cannot read UDP2RAW_PASSWORD_FILE' "$tmp/rejection.log"
done
docker network create "$network" >/dev/null

docker run -d --name "$server" --network "$network" \
    --cap-add NET_ADMIN --cap-add NET_RAW \
    --sysctl net.ipv4.conf.all.src_valid_mark=1 \
    -e ROLE=server -e UDP2RAW_PASSWORD=test-password -e SPEEDER_ENABLED="$speeder" \
    -v "$tmp/server.conf:/config/wg0.conf:ro" "$image" >/dev/null
server_ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$server")

docker run -d --name "$client" --network "$network" \
    --cap-add NET_ADMIN --cap-add NET_RAW \
    --sysctl net.ipv4.conf.all.src_valid_mark=1 \
    -e ROLE=client -e UDP2RAW_REMOTE_HOST="$server_ip" \
    -e UDP2RAW_PASSWORD_FILE=/run/secrets/password -e SPEEDER_ENABLED="$speeder" \
    -e SPEEDER_FEC=10:3 -e SPEEDER_TIMEOUT=5 -e SPEEDER_MTU=1200 \
    -v "$tmp/password:/run/secrets/password:ro" \
    -v "$tmp/client.conf:/config/wg0.conf:ro" "$image" >/dev/null

for _ in $(seq 1 20); do
    handshake=$(docker exec "$client" wg show wg0 latest-handshakes 2>/dev/null | awk 'NR == 1 { print $2 }')
    if [ "${handshake:-0}" -gt 0 ]; then
        docker exec "$client" healthcheck.sh
        docker exec "$server" healthcheck.sh
        [ "$(docker exec "$client" cat /sys/class/net/wg0/mtu)" = 1280 ]
        [ "$(docker exec "$server" cat /sys/class/net/wg0/mtu)" = 1280 ]
        docker stop -t 10 "$client" "$server" >/dev/null
        [ "$(docker inspect -f '{{.State.ExitCode}}' "$client")" -eq 0 ]
        [ "$(docker inspect -f '{{.State.ExitCode}}' "$server")" -eq 0 ]
        echo "WireGuard handshake and clean shutdown succeeded (UDPspeeder: $speeder, $server_ip)"
        exit 0
    fi
    sleep 1
done

echo 'client logs:' >&2
docker logs "$client" >&2 || true
echo 'server logs:' >&2
docker logs "$server" >&2 || true
exit 1
