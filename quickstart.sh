#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
prompt() {
    local answer
    read -r -p "$2 [$3]: " answer || die 'Input cancelled.'
    printf -v "$1" '%s' "${answer:-$3}"
}
ipv4() {
    local part
    local -a parts
    [[ $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    IFS=. read -r -a parts <<< "$1"
    for part in "${parts[@]}"; do
        [[ $part == 0 || $part =~ ^[1-9][0-9]{0,2}$ ]] || return 1
        ((10#$part <= 255)) || return 1
    done
}
hostname_ok() {
    local label
    local -a labels
    [[ ${#1} -le 253 && $1 != *. ]] || return 1
    if [[ $1 =~ ^[0-9.]+$ ]]; then ipv4 "$1"; return; fi
    IFS=. read -r -a labels <<< "$1"
    for label in "${labels[@]}"; do
        [[ $label =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]] || return 1
    done
    [[ ${#labels[@]} -gt 0 ]]
}

[[ $# -le 1 ]] || die 'Usage: bash quickstart.sh [new-output-directory]'
if [[ ${1:-} == --help ]]; then
    printf 'Usage: bash quickstart.sh [new-output-directory]\nGenerate a server and one client, plus a portable client archive. Requires wg or Docker.\n'
    exit 0
fi
out=${1:-"$root/quickstart-output"}
[[ ! -e $out && ! -L $out ]] || die "Output already exists: $out (choose a new directory; existing keys are never overwritten)."
image=${WG_RESILIENT_IMAGE:-criogaid/wg-resilient:latest}
[[ $image =~ ^[A-Za-z0-9][A-Za-z0-9._:/@-]*$ ]] || die 'Invalid WG_RESILIENT_IMAGE.'

printf 'WG Resilient: generate a server and one client. No existing configuration will be changed.\n'
while :; do
    prompt host 'Server public IPv4 or DNS name (no scheme or port)' ''
    hostname_ok "$host" && break
    printf 'Enter a valid IPv4 address or DNS name.\n'
done
while :; do
    prompt port 'FakeTCP port' 4096
    [[ $port =~ ^[1-9][0-9]{0,4}$ ]] && ((port <= 65535)) && break
    printf 'Port must be 1-65535.\n'
done
while :; do
    prompt network 'Tunnel /24 network (server .1, client .2)' 10.66.66.0
    if ipv4 "$network" && [[ $network == *.0 ]]; then
        prefix=${network%.0}
        [[ $network == 10.* || $network == 192.168.* || $network =~ ^172\.(1[6-9]|2[0-9]|3[01])\. ]] && break
    fi
    printf 'Enter a private IPv4 /24 network ending in .0, without /24.\n'
done
while :; do
    prompt mtu 'WireGuard MTU' 1280
    [[ $mtu =~ ^[0-9]{3,4}$ && $mtu != 0* ]] && ((mtu >= 576 && mtu <= 9000)) && break
    printf 'MTU must be 576-9000.\n'
done
while :; do
    prompt dns 'Client DNS IPv4' 1.1.1.1
    ipv4 "$dns" && break
    printf 'Enter a valid IPv4 address.\n'
done
while :; do
    prompt routing 'Client routes: full or tunnel' full
    [[ $routing == full || $routing == tunnel ]] && break
    printf 'Choose full or tunnel.\n'
done
allowed=0.0.0.0/0
[[ $routing != tunnel ]] || allowed="$network/24"
while :; do
    prompt speeder 'Enable UDPspeeder on both ends: true or false' false
    [[ $speeder == true || $speeder == false ]] && break
    printf 'Choose true or false.\n'
done

if command -v wg >/dev/null 2>&1; then
    wg_cmd=(wg)
else
    command -v docker >/dev/null 2>&1 || die 'Install wireguard-tools (wg) or Docker to generate keys.'
    printf 'Pulling %s to use its WireGuard key generator...\n' "$image"
    docker pull "$image" </dev/null
    wg_cmd=(docker run --rm -i --entrypoint wg "$image")
fi
server_private=$("${wg_cmd[@]}" genkey </dev/null)
server_public=$(printf '%s\n' "$server_private" | "${wg_cmd[@]}" pubkey)
client_private=$("${wg_cmd[@]}" genkey </dev/null)
client_public=$(printf '%s\n' "$client_private" | "${wg_cmd[@]}" pubkey)
psk=$("${wg_cmd[@]}" genpsk </dev/null)
password=$("${wg_cmd[@]}" genpsk </dev/null)
password=${password//\//_}
password=${password//+/-}
password=${password%=}
for key in "$server_private" "$server_public" "$client_private" "$client_public" "$psk"; do
    [[ $key =~ ^[A-Za-z0-9+/]{43}=$ ]] || die 'wg returned an invalid key.'
done
[[ $password =~ ^[A-Za-z0-9_-]{43}$ ]] || die 'wg returned an invalid password.'

mkdir -m 700 -- "$out"
out=$(cd -- "$out" && pwd)
complete=false
cleanup() { $complete || rm -rf -- "$out"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
for role in server client; do
    target="$out/$role"
    mkdir -p -- "$target/config/$role"
    cp -- "$root/compose.$role.yml" "$target/compose.yml"
    cp -- "$root/entrypoint.sh" "$target/"
    chmod 700 "$target/entrypoint.sh"
    printf 'WG_RESILIENT_IMAGE=%s\nUDP2RAW_REMOTE_HOST=%s\nUDP2RAW_PORT=%s\nUDP2RAW_PASSWORD=%s\nSPEEDER_ENABLED=%s\n' \
        "$image" "$host" "$port" "$password" "$speeder" > "$target/.env"
    sed -e 's/\r$//' \
        -e "s|SERVER_PRIVATE_KEY|$server_private|g" \
        -e "s|SERVER_PUBLIC_KEY|$server_public|g" \
        -e "s|CLIENT_PRIVATE_KEY|$client_private|g" \
        -e "s|CLIENT_PUBLIC_KEY|$client_public|g" \
        -e "s|10.66.66.|$prefix.|g" \
        -e "s|MTU = 1280|MTU = $mtu|" \
        -e "s|DNS = 1.1.1.1|DNS = $dns|" \
        -e "s|AllowedIPs = 0.0.0.0/0|AllowedIPs = $allowed|" \
        -e "/^PublicKey = /a PresharedKey = $psk" \
        "$root/config/$role/wg0.conf.example" > "$target/config/$role/wg0.conf"
    cat > "$target/deploy.sh" <<'DEPLOY'
#!/usr/bin/env bash
set -Eeuo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
command -v docker >/dev/null 2>&1 || { echo 'Install Docker Engine and Compose v2 first.' >&2; exit 1; }
docker info >/dev/null
docker compose version >/dev/null
chmod 600 .env config/*/wg0.conf
unset WG_RESILIENT_IMAGE UDP2RAW_REMOTE_HOST UDP2RAW_PORT UDP2RAW_PASSWORD UDP2RAW_PASSWORD_FILE
unset SPEEDER_ENABLED SPEEDER_FEC SPEEDER_MTU SPEEDER_TIMEOUT COMPOSE_FILE COMPOSE_PROJECT_NAME
exec docker compose --project-name wg-resilient-ROLE --env-file .env -f compose.yml up -d --pull always --no-build --wait --wait-timeout 120
DEPLOY
    sed "s/wg-resilient-ROLE/wg-resilient-$role/" "$target/deploy.sh" > "$target/deploy.tmp"
    mv -- "$target/deploy.tmp" "$target/deploy.sh"
    chmod 700 "$target/deploy.sh"
    chmod 600 "$target/.env" "$target/config/$role/wg0.conf"
done
tar -czf "$out/client.tar.gz" -C "$out" client
complete=true
printf '\nGenerated server config: %s/server/config/server/wg0.conf\n' "$out"
printf 'Start server: bash %q/server/deploy.sh\n' "$out"
printf 'Transfer ONLY %s/client.tar.gz to the client via scp/SFTP. It contains private keys.\n' "$out"
printf 'Copy client (replace SSH target): scp %q/client.tar.gz user@client-host:~/\n' "$out"
printf 'On client: umask 077; mkdir wg-client && tar -xzf ~/client.tar.gz -C wg-client && bash wg-client/client/deploy.sh\n'
printf 'Allow TCP %s on the server firewall. Tunnel: %s.1 <-> %s.2\n' "$port" "$prefix" "$prefix"
printf 'The client archive must be used by ONE client only. Tunnel routes apply inside its container, not the host.\n'
prompt start 'Deploy server now? y/N' N
case $start in y|Y) bash "$out/server/deploy.sh" ;; esac
