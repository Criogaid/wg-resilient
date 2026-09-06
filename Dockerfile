FROM debian:bookworm-slim AS build

ARG UDP2RAW_COMMIT=e5ecd33ec4c25d499a14213a5d1dbd5d21e0dd63
ARG UDPSPEEDER_COMMIT=61b24a369700c3d8248dd18fa9a524b778741454

RUN apt-get update \
    && apt-get install -y --no-install-recommends build-essential ca-certificates git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
RUN git init udp2raw \
    && git -C udp2raw fetch --depth 1 https://github.com/wangyu-/udp2raw.git "${UDP2RAW_COMMIT}" \
    && git -C udp2raw checkout --detach FETCH_HEAD \
    && make -C udp2raw dynamic \
    && git init udpspeeder \
    && git -C udpspeeder fetch --depth 1 https://github.com/wangyu-/UDPspeeder.git "${UDPSPEEDER_COMMIT}" \
    && git -C udpspeeder checkout --detach FETCH_HEAD \
    && make -C udpspeeder fast

FROM debian:bookworm-slim

LABEL org.opencontainers.image.source="https://github.com/wangyu-/udp2raw" \
      org.opencontainers.image.title="WG Resilient" \
      org.opencontainers.image.description="WireGuard for UDP-restricted and lossy networks, with udp2raw and optional UDPspeeder"

RUN apt-get update \
    && apt-get install -y --no-install-recommends iproute2 iptables libstdc++6 openresolv procps tini wireguard-tools \
    && rm -rf /var/lib/apt/lists/*

COPY --from=build /src/udp2raw/udp2raw_dynamic /usr/local/bin/udp2raw
COPY --from=build /src/udpspeeder/speederv2 /usr/local/bin/speederv2
COPY --from=build /src/udp2raw/LICENSE.md /usr/share/doc/udp2raw/copyright
COPY --from=build /src/udpspeeder/LICENSE.md /usr/share/doc/udpspeeder/copyright
COPY entrypoint.sh healthcheck.sh /usr/local/bin/
COPY sysctl-wrapper.sh /usr/local/bin/sysctl
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/healthcheck.sh /usr/local/bin/sysctl

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 CMD ["healthcheck.sh"]
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
