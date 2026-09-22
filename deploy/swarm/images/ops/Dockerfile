# The SWARM operations image: the one-shot genesis job and the deploy-time
# health checks.
#
# Deliberately boring: curl, jq and python3 in a slim base, no network fetches
# at build time and no compiler. python3 is here for one job - decoding the
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
        jq \
        python3 \
    && rm -rf /var/lib/apt/lists/*

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
