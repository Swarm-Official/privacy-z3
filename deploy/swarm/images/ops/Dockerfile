# The SWARM operations image: the one-shot genesis job and the deploy-time
# health checks.
#
# Deliberately boring: curl, jq and python3 in a slim base, no compiler, and a
# single, pinned, checksummed build-time fetch (the IP-to-city database the live
# heat map reads; see below). python3 is here for one job - decoding the
# protobuf fields of a GetLightdInfo response without pulling in grpcurl and
# the lightwallet protos - and for nothing else.
#
# `python3`, not `python3-minimal`: the minimal package omits most of the
# standard library, including `json`, which the decoder needs to print its
# result. The difference is about 25 MB and one confusing ImportError.
#
# Build context: deploy/swarm
FROM debian:bookworm-slim

ARG SWARM_UID=10001
ARG SWARM_GID=10001

# hadolint ignore=DL3008
RUN apt-get -o Acquire::Retries=3 update \
    && apt-get -o Acquire::Retries=3 install -y --no-install-recommends \
        ca-certificates \
        curl \
        gzip \
        jq \
        python3 \
        python3-pip \
    && rm -rf /var/lib/apt/lists/*

# The IP-to-city database and its reader, for the live heat map
# (swarm-map-live.json). This is the ONE network fetch the image makes: a
# monthly dump from DB-IP's free City Lite (Creative Commons, attribution in
# the file's own "note" and on the website), compressed and verified by its
# sha256 before it is unpacked, so a changed or truncated download fails the
# build. `maxminddb` reads it offline; nothing here reaches the network at
# runtime. Bump the YYYY-MM in the URL and the checksum together each month.
RUN python3 -m pip install --no-cache-dir --break-system-packages maxminddb==2.6.2 \
    && mkdir -p /swarm/geo \
    && curl -fsSL "https://download.db-ip.com/free/dbip-city-lite-2026-08.mmdb.gz" -o /tmp/city.mmdb.gz \
    && echo "2b53203ec36a975051a8189dc1207d624e3bc302fbee47648928476533be69d1  /tmp/city.mmdb.gz" | sha256sum -c - \
    && gzip -d /tmp/city.mmdb.gz \
    && mv /tmp/city.mmdb /swarm/geo/city.mmdb

# The same uid as the node, so the 0600 RPC cookie in the shared volume is
# readable here too.
RUN groupadd --gid "${SWARM_GID}" swarm \
    && useradd --uid "${SWARM_UID}" --gid "${SWARM_GID}" \
        --home-dir /swarm --no-create-home --shell /usr/sbin/nologin swarm \
    && mkdir -p /swarm/auth /swarm/config /swarm/public \
    && chown -R "${SWARM_UID}:${SWARM_GID}" /swarm

COPY --chmod=0755 images/ops/rpc.sh /usr/local/bin/swarm-rpc
COPY --chmod=0755 images/ops/init-genesis.sh /usr/local/bin/swarm-init-genesis
COPY --chmod=0755 images/ops/lightd-info.sh /usr/local/bin/swarm-lightd-info
COPY --chmod=0755 images/ops/lightd_info_decode.py /usr/local/bin/swarm-lightd-decode
COPY --chmod=0755 images/ops/status-json.py /usr/local/bin/swarm-status-json

USER swarm
WORKDIR /swarm

ENTRYPOINT []
CMD ["swarm-init-genesis"]
