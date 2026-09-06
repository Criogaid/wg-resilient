#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
active=false
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
    rm -rf -- "$tmp"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if command -v wg >/dev/null 2>&1; then
    wg_cmd=(wg)
else
    wg_cmd=(docker run --rm -i --entrypoint wg wg-resilient:local)
fi
value() { sed -n "s/^$1 = //p" "$2"; }

printf 'https://bad\n999.1.1.1\nvpn.example.com\n0\n65536\n4096\n8.8.8.0\n10.99.0.0\n0\n1300\nbad\n9.9.9.9\nbad\ntunnel\nbad\ntrue\nN\n' |
    bash "$root/quickstart.sh" "$tmp/custom setup" > "$tmp/output"
s="$tmp/custom setup/server/config/server/wg0.conf"
c="$tmp/custom setup/client/config/client/wg0.conf"
[[ $(value PrivateKey "$s") != "$(value PrivateKey "$c")" ]]
[[ $(value PrivateKey "$s" | "${wg_cmd[@]}" pubkey) == "$(value PublicKey "$c")" ]]
[[ $(value PrivateKey "$c" | "${wg_cmd[@]}" pubkey) == "$(value PublicKey "$s")" ]]
[[ $(value PresharedKey "$s") == "$(value PresharedKey "$c")" ]]
[[ $(value Address "$s") == 10.99.0.1/24 ]]
[[ $(value Address "$c") == 10.99.0.2/24 ]]
[[ $(value AllowedIPs "$c") == 10.99.0.0/24 ]]
[[ $(value MTU "$c") == 1300 && $(value DNS "$c") == 9.9.9.9 ]]
grep -q -- '-s 10.99.0.0/24' "$s"
grep -q '^SPEEDER_ENABLED=true$' "$tmp/custom setup/client/.env"
cmp "$tmp/custom setup/server/.env" "$tmp/custom setup/client/.env"
! grep -Fq "$(value PrivateKey "$s")" "$tmp/output"
! grep -Fq "$(value PrivateKey "$c")" "$tmp/output"
[[ $(stat -c %a "$s") == 600 && $(stat -c %a "$tmp/custom setup") == 700 ]]
[[ $(stat -c %a "$tmp/custom setup/client.tar.gz") == 600 ]]
mkdir "$tmp/unpacked"
tar -xzf "$tmp/custom setup/client.tar.gz" -C "$tmp/unpacked"
diff -r "$tmp/custom setup/client" "$tmp/unpacked/client"
! grep -rFq "$(value PrivateKey "$s")" "$tmp/unpacked"
if bash "$root/quickstart.sh" "$tmp/custom setup" </dev/null > /dev/null 2>&1; then exit 1; fi
if bash "$root/quickstart.sh" "$tmp/cancelled" </dev/null > /dev/null 2>&1; then exit 1; fi
[[ ! -e $tmp/cancelled ]]

printf '192.0.2.1\n\n\n\n\n\n\nN\n' | bash "$root/quickstart.sh" "$tmp/defaults" >/dev/null
[[ $(value AllowedIPs "$tmp/defaults/client/config/client/wg0.conf") == 0.0.0.0/0 ]]
[[ $(value PrivateKey "$tmp/defaults/client/config/client/wg0.conf") != "$(value PrivateKey "$c")" ]]

mkdir "$tmp/bin"
cat > "$tmp/bin/docker" <<'MOCK'
#!/usr/bin/env bash
set -eu
case "$*" in info|'compose version') exit 0 ;; esac
[[ -z ${UDP2RAW_PASSWORD+x}${UDP2RAW_PASSWORD_FILE+x}${UDP2RAW_REMOTE_HOST+x}${SPEEDER_ENABLED+x} ]] || exit 91
printf '%s\n' "$*" > "$DEPLOY_CALL"
exit 42
MOCK
chmod +x "$tmp/bin/docker"
status=0
PATH="$tmp/bin:$PATH" DEPLOY_CALL="$tmp/deploy-call" UDP2RAW_PASSWORD=wrong \
    UDP2RAW_PASSWORD_FILE=wrong UDP2RAW_REMOTE_HOST=wrong SPEEDER_ENABLED=wrong \
    bash "$tmp/unpacked/client/deploy.sh" || status=$?
[[ $status == 42 ]]
grep -Fxq 'compose --project-name wg-resilient-client --env-file .env -f compose.yml up -d --build --wait --wait-timeout 120' "$tmp/deploy-call"

if [[ ${1:-} == --e2e ]]; then
    for role in server client; do
        [[ -z $(docker ps -aq --filter "label=com.docker.compose.project=wg-resilient-$role") ]] || {
            echo 'Refusing to touch existing quickstart deployment.' >&2; exit 1;
        }
    done
    host=$(docker network inspect bridge --format '{{(index .IPAM.Config 0).Gateway}}')
    for speeder in false true; do
        printf '%s\n24096\n10.98.0.0\n\n\n\n%s\ny\n' "$host" "$speeder" > "$tmp/answers"
        active=true
        bash "$root/quickstart.sh" "$tmp/run" < "$tmp/answers" > "$tmp/deploy.log" 2>&1 || { cat "$tmp/deploy.log"; exit 1; }
        mkdir "$tmp/transfer"
        tar -xzf "$tmp/run/client.tar.gz" -C "$tmp/transfer"
        rm -rf "$tmp/run/client"
        mv "$tmp/transfer/client" "$tmp/run/client"
        rmdir "$tmp/transfer"
        UDP2RAW_PASSWORD=wrong SPEEDER_ENABLED=wrong UDP2RAW_REMOTE_HOST=wrong \
            bash "$tmp/run/client/deploy.sh" >> "$tmp/deploy.log" 2>&1 || { cat "$tmp/deploy.log"; exit 1; }
        client_id=$(compose client ps -q)
        server_id=$(compose server ps -q)
        handshake=0
        for ((i=0; i<30; i++)); do
            handshake=$(docker exec "$client_id" wg show wg0 latest-handshakes | awk 'NR == 1 {print $2}')
            [[ ${handshake:-0} -gt 0 ]] && break
            sleep 1
        done
        if [[ ${handshake:-0} -eq 0 ]]; then
            docker exec -t "$client_id" ip -4 rule
            docker exec -t "$client_id" ip -4 route show table all
            docker logs "$client_id" 2>&1 | grep -E 'source_addr|state changed|state back' | tail -10
            echo 'Generated deployment did not handshake.' >&2
            exit 1
        fi
        docker exec "$client_id" healthcheck.sh
        docker exec "$server_id" healthcheck.sh
        docker exec "$client_id" ip -4 rule | awk '
            /lookup main/ && /to / { bypass=$1+0 }
            /fwmark/ { tunnel=$1+0 }
            END { exit !(bypass > 0 && tunnel > bypass) }'
        echo "Generated archive deployed and WireGuard handshake passed (speeder=$speeder)"
        compose client down
        compose server down
        active=false
        rm -rf "$tmp/run"
    done
fi
echo 'quickstart checks passed'
