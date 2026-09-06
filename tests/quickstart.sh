#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
active=false
network=
host_server=wg-host-server-$$
host_client=wg-host-client-$$
image=${WG_RESILIENT_IMAGE:-criogaid/wg-resilient:latest}
compose() {
    local role=$1
    shift
    docker compose -p "wg-resilient-$role" --env-file "$tmp/run/$role/.env" -f "$tmp/run/$role/compose.yml" "$@"
}
cleanup() {
    if $active; then
        compose client down >/dev/null 2>&1 || true
        compose server down >/dev/null 2>&1 || true
    fi
    if [[ -n $network ]]; then
        docker rm -f "$host_server-http" "$host_client-http" "$host_client" "$host_server" >/dev/null 2>&1 || true
        docker network rm "$network" >/dev/null 2>&1 || true
    fi
    rm -rf -- "$tmp"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if command -v wg >/dev/null 2>&1; then
    wg_cmd=(wg)
else
    wg_cmd=(docker run --rm -i --entrypoint wg "$image")
fi
value() { sed -n "s/^$1 = //p" "$2"; }

printf 'https://bad\n999.1.1.1\nvpn.example.com\n0\n65536\n4096\n8.8.8.0\n10.99.0.0\n0\n1300\nbad\ntrue\nN\n' |
    WG_INTERFACE=wg-custom bash "$root/quickstart.sh" "$tmp/custom setup" > "$tmp/output"
s="$tmp/custom setup/server/config/server/wg0.conf"
c="$tmp/custom setup/client/config/client/wg0.conf"
[[ $(value PrivateKey "$s") != "$(value PrivateKey "$c")" ]]
[[ $(value PrivateKey "$s" | "${wg_cmd[@]}" pubkey) == "$(value PublicKey "$c")" ]]
[[ $(value PrivateKey "$c" | "${wg_cmd[@]}" pubkey) == "$(value PublicKey "$s")" ]]
[[ $(value PresharedKey "$s") == "$(value PresharedKey "$c")" ]]
[[ $(value Address "$s") == 10.99.0.1/24 ]]
[[ $(value Address "$c") == 10.99.0.2/24 ]]
[[ $(value AllowedIPs "$c") == 10.99.0.0/24 ]]
[[ $(value MTU "$c") == 1300 && -z $(value DNS "$c") ]]
grep -q '^SPEEDER_ENABLED=true$' "$tmp/custom setup/client/.env"
cmp "$tmp/custom setup/server/.env" "$tmp/custom setup/client/.env"
grep -Fxq "WG_RESILIENT_IMAGE=$image" "$tmp/custom setup/client/.env"
grep -Fxq 'WG_INTERFACE=wg-custom' "$tmp/custom setup/client/.env"
for role in server client; do
    [[ ! -e "$tmp/custom setup/$role/Dockerfile" ]]
    ! grep -Eq '^ +(build|ports|sysctls):' "$tmp/custom setup/$role/compose.yml" || exit 1
    grep -Fq 'network_mode: host' "$tmp/custom setup/$role/compose.yml"
    ! grep -Eq '^(PostUp|PostDown|DNS)|0\.0\.0\.0/0' "$tmp/custom setup/$role/config/$role/wg0.conf" || exit 1
    for script in entrypoint.sh healthcheck.sh; do
        cmp "$root/$script" "$tmp/custom setup/$role/$script"
        [[ -x "$tmp/custom setup/$role/$script" ]]
    done
done
! grep -Fq "$(value PrivateKey "$s")" "$tmp/output" || exit 1
! grep -Fq "$(value PrivateKey "$c")" "$tmp/output" || exit 1
[[ $(stat -c %a "$s") == 600 && $(stat -c %a "$tmp/custom setup") == 700 ]]
[[ $(stat -c %a "$tmp/custom setup/client.tar.gz") == 600 ]]
mkdir "$tmp/unpacked"
tar -xzf "$tmp/custom setup/client.tar.gz" -C "$tmp/unpacked"
diff -r "$tmp/custom setup/client" "$tmp/unpacked/client"
! grep -rFq "$(value PrivateKey "$s")" "$tmp/unpacked" || exit 1
if bash "$root/quickstart.sh" "$tmp/custom setup" </dev/null >/dev/null 2>&1; then exit 1; fi
if bash "$root/quickstart.sh" "$tmp/cancelled" </dev/null >/dev/null 2>&1; then exit 1; fi
[[ ! -e $tmp/cancelled ]]
for invalid in ../wg0 'bad name' 1234567890123456 '-wg0'; do
    if WG_INTERFACE="$invalid" bash "$root/quickstart.sh" "$tmp/invalid" </dev/null >/dev/null 2>&1; then exit 1; fi
    [[ ! -e $tmp/invalid ]]
done

printf '192.0.2.1\n\n\n\n\nN\n' | env -u WG_INTERFACE bash "$root/quickstart.sh" "$tmp/defaults" >/dev/null
grep -Fxq 'WG_INTERFACE=wg0' "$tmp/defaults/client/.env"
[[ $(value AllowedIPs "$tmp/defaults/client/config/client/wg0.conf") == 10.66.66.0/24 ]]
[[ $(value PrivateKey "$tmp/defaults/client/config/client/wg0.conf") != "$(value PrivateKey "$c")" ]]

mkdir "$tmp/bin"
cat > "$tmp/bin/docker" <<'MOCK'
#!/usr/bin/env bash
set -eu
case "$*" in info|'compose version') exit 0 ;; esac
[[ -z ${WG_INTERFACE+x}${WG_RESILIENT_IMAGE+x}${UDP2RAW_PASSWORD+x}${UDP2RAW_PASSWORD_FILE+x}${UDP2RAW_REMOTE_HOST+x}${SPEEDER_ENABLED+x} ]] || exit 91
printf '%s\n' "$*" > "$DEPLOY_CALL"
exit 42
MOCK
chmod +x "$tmp/bin/docker"
status=0
PATH="$tmp/bin:$PATH" DEPLOY_CALL="$tmp/deploy-call" UDP2RAW_PASSWORD=wrong \
    WG_INTERFACE=wrong WG_RESILIENT_IMAGE=wrong UDP2RAW_PASSWORD_FILE=wrong UDP2RAW_REMOTE_HOST=wrong SPEEDER_ENABLED=wrong \
    bash "$tmp/unpacked/client/deploy.sh" || status=$?
[[ $status == 42 ]]
grep -Fxq 'compose --project-name wg-resilient-client --env-file .env -f compose.yml up -d --pull always --no-build --wait --wait-timeout 120' "$tmp/deploy-call"

if [[ ${1:-} == --e2e ]]; then
    for role in server client; do
        [[ -z $(docker ps -aq --filter "label=com.docker.compose.project=wg-resilient-$role") ]] || {
            echo 'Refusing to touch existing quickstart deployment.' >&2; exit 1;
        }
    done
    network=wg-host-test-$$
    docker network create "$network" >/dev/null
    mkdir "$tmp/www"
    printf 'host-service-ok\n' > "$tmp/www/index.html"
    for host in "$host_server" "$host_client"; do
        docker run -d --name "$host" --network "$network" --cap-add NET_ADMIN \
            --entrypoint sleep "$image" infinity >/dev/null
        docker run -d --name "$host-http" --network "container:$host" \
            -v "$tmp/www:/www:ro" busybox:1.37 httpd -f -p 8848 -h /www >/dev/null
        docker exec "$host" ip -4 rule > "$tmp/$host.rules"
        docker exec "$host" ip -4 route show default > "$tmp/$host.default"
        docker exec "$host" iptables -t nat -S > "$tmp/$host.nat"
        docker exec "$host" iptables -S > "$tmp/$host.filter"
        docker exec "$host" cat /proc/sys/net/ipv4/ip_forward > "$tmp/$host.forward"
    done
    host=$(docker inspect "$host_server" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
    for speeder in false true; do
        server_interface=wg0
        [[ $speeder == false ]] || server_interface=wg-server
        printf '%s\n24096\n10.98.0.0\n\n%s\nN\n' "$host" "$speeder" |
            WG_INTERFACE="$server_interface" bash "$root/quickstart.sh" "$tmp/run" > "$tmp/deploy.log" 2>&1
        mkdir "$tmp/transfer"
        tar -xzf "$tmp/run/client.tar.gz" -C "$tmp/transfer"
        rm -rf "$tmp/run/client"
        mv "$tmp/transfer/client" "$tmp/run/client"
        rmdir "$tmp/transfer"
        sed -i 's/^WG_INTERFACE=.*/WG_INTERFACE=wg-client/' "$tmp/run/client/.env"
        for role in server client; do
            sed -i "s|network_mode: host|network_mode: container:wg-host-$role-$$|" "$tmp/run/$role/compose.yml"
        done
        active=true
        for role in server client; do
            WG_INTERFACE=ignored bash "$tmp/run/$role/deploy.sh" >> "$tmp/deploy.log" 2>&1 || { cat "$tmp/deploy.log"; exit 1; }
        done
        client_id=$(compose client ps -q)
        server_id=$(compose server ps -q)
        handshake=0
        for ((i=0; i<30; i++)); do
            handshake=$(docker exec "$host_client" wg show wg-client latest-handshakes | awk 'NR == 1 {print $2}')
            [[ ${handshake:-0} -gt 0 ]] && break
            sleep 1
        done
        [[ ${handshake:-0} -gt 0 ]] || { echo 'Host tunnel did not handshake.' >&2; exit 1; }
        docker exec "$client_id" healthcheck.sh
        docker exec "$server_id" healthcheck.sh
        docker exec "$host_server" wg show "$server_interface" >/dev/null
        [[ $(docker run --rm --network "container:$host_client" busybox:1.37 wget -q -T 10 -O - http://10.98.0.1:8848) == host-service-ok ]]
        [[ $(docker run --rm --network "container:$host_server" busybox:1.37 wget -q -T 10 -O - http://10.98.0.2:8848) == host-service-ok ]]
        for machine in "$host_server" "$host_client"; do
            docker exec "$machine" ip -4 rule | diff "$tmp/$machine.rules" -
            docker exec "$machine" ip -4 route show default | diff "$tmp/$machine.default" -
            docker exec "$machine" iptables -t nat -S | diff "$tmp/$machine.nat" -
            docker exec "$machine" cat /proc/sys/net/ipv4/ip_forward | diff "$tmp/$machine.forward" -
        done
        if docker run --rm --network "container:$host_server" --cap-add NET_ADMIN \
            -e ROLE=server -e WG_INTERFACE="$server_interface" -e UDP2RAW_PASSWORD=test \
            -v "$root/entrypoint.sh:/usr/local/bin/entrypoint.sh:ro" \
            -v "$tmp/run/server/config/server/wg0.conf:/config/wg0.conf:ro" "$image" > "$tmp/conflict.log" 2>&1; then exit 1; fi
        grep -q 'interface already exists' "$tmp/conflict.log"
        docker exec "$host_server" wg show "$server_interface" >/dev/null
        compose client stop -t 10 >/dev/null
        compose server stop -t 10 >/dev/null
        [[ $(docker inspect "$client_id" --format '{{.State.ExitCode}}') == 0 ]]
        [[ $(docker inspect "$server_id" --format '{{.State.ExitCode}}') == 0 ]]
        if docker exec "$host_client" ip link show wg-client >/dev/null 2>&1; then exit 1; fi
        if docker exec "$host_server" ip link show "$server_interface" >/dev/null 2>&1; then exit 1; fi
        for machine in "$host_server" "$host_client"; do
            docker exec "$machine" iptables -S | diff "$tmp/$machine.filter" -
        done
        compose client down >/dev/null
        compose server down >/dev/null
        active=false
        rm -rf "$tmp/run"
        echo "Host services reachable both ways without NAT or policy rules; interface cleanup passed (speeder=$speeder)"
    done
    for invalid in ../wg0 'bad name' 1234567890123456; do
        if docker run --rm -e ROLE=server -e WG_INTERFACE="$invalid" \
            -v "$root/entrypoint.sh:/usr/local/bin/entrypoint.sh:ro" "$image" > "$tmp/invalid.log" 2>&1; then exit 1; fi
        grep -q 'WG_INTERFACE must be' "$tmp/invalid.log"
    done
    sed 's|AllowedIPs = .*|AllowedIPs = 0.0.0.0/0|' "$c" > "$tmp/legacy.conf"
    if docker run --rm --cap-add NET_ADMIN -e ROLE=client -e UDP2RAW_PASSWORD=test \
        -v "$root/entrypoint.sh:/usr/local/bin/entrypoint.sh:ro" \
        -v "$tmp/legacy.conf:/config/wg0.conf:ro" "$image" > "$tmp/legacy.log" 2>&1; then exit 1; fi
    grep -q 'default routes are not supported' "$tmp/legacy.log"
fi
echo 'quickstart checks passed'
