#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

bash -n entrypoint.sh
bash -n quickstart.sh
bash -n tests/quickstart.sh
sh -n healthcheck.sh
sh -n sysctl-wrapper.sh
sh -n tests/e2e.sh
grep -q 'Endpoint = 127.0.0.1:51821' config/client/wg0.conf.example
! grep -q 'ip -4 rule add' entrypoint.sh || exit 1
! grep -Eq 'PostUp|PostDown|DNS =|0\.0\.0\.0/0' config/*/wg0.conf.example || exit 1
for role in server client; do
    grep -q 'network_mode: host' "compose.$role.yml"
    ! grep -Eq '^ +(ports|sysctls|build):' "compose.$role.yml" || exit 1
done

if command -v docker >/dev/null 2>&1; then
    UDP2RAW_PASSWORD=test-password UDP2RAW_REMOTE_HOST=192.0.2.1 \
        docker compose -f compose.server.yml config >/dev/null
    UDP2RAW_PASSWORD=test-password UDP2RAW_REMOTE_HOST=192.0.2.1 \
        docker compose -f compose.client.yml config >/dev/null
else
    echo 'docker not found; skipped Compose validation'
fi

echo 'checks passed'
