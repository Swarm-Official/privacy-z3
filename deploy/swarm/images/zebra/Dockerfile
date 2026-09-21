# The SWARM seed node: the prebuilt `zebrad` in a slim runtime image.
#
# No compiler and no source. `bin/zebrad` is the artifact of the "SWARM native
# binaries" workflow in brs-holding/privacy-zebra: the official Zebra v6.3.0
# tag built with `--locked` plus the optional `internal-miner` feature, and
# nothing else changed. The official zfnd/zebra image cannot be used because
# that feature is not in it.
#
# Build context: deploy/swarm
FROM debian:bookworm-slim

ARG SWARM_UID=10001
ARG SWARM_GID=10001

# Runtime libraries only. zebrad is a Rust binary that links glibc, libgcc and
# libstdc++ (RocksDB's C++ core); curl is here for the health check, which has
# to authenticate to the node's RPC.
# hadolint ignore=DL3008
RUN apt-get -o Acquire::Retries=3 update \
    && apt-get -o Acquire::Retries=3 install -y --no-install-recommends \
        ca-certificates \
        curl \
        libgcc-s1 \
        libstdc++6 \
    && rm -rf /var/lib/apt/lists/*

# A fixed, non-root uid shared with the indexer image. Zebra writes its RPC
# cookie with mode 0600, so the indexer can only read it if both run as the
# same user; that is the whole reason the number is pinned here rather than
# left to the base image.
RUN groupadd --gid "${SWARM_GID}" swarm \
    && useradd --uid "${SWARM_UID}" --gid "${SWARM_GID}" \
        --home-dir /swarm --no-create-home --shell /usr/sbin/nologin swarm \
    && mkdir -p /swarm/state /swarm/auth /swarm/config \
    && chown -R "${SWARM_UID}:${SWARM_GID}" /swarm

# An empty named volume mounted over /swarm/auth inherits this directory's
# ownership, which is what lets the unprivileged node create its cookie there.
VOLUME ["/swarm/state", "/swarm/auth"]

COPY --chmod=0755 bin/zebrad /usr/local/bin/zebrad
COPY --chmod=0755 images/zebra/entrypoint.sh /usr/local/bin/swarm-zebra-entrypoint
COPY --chmod=0755 images/zebra/healthcheck.sh /usr/local/bin/swarm-zebra-health

USER swarm
WORKDIR /swarm

# P2P. The RPC port is deliberately not exposed: it is reached by service name
# on the internal network and is never published.
EXPOSE 18233

HEALTHCHECK --interval=30s --timeout=10s --start-period=120s --retries=5 \
    CMD ["swarm-zebra-health"]

ENTRYPOINT ["/usr/local/bin/swarm-zebra-entrypoint"]
CMD ["start"]
