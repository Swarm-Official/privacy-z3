# The SWARM light-wallet indexer: the prebuilt `zainod` in a slim runtime image.
#
# No compiler and no source. `bin/zainod` is the artifact of the "SWARM zainod
# binary" workflow in brs-holding/privacy-zaino, branch swarm-testnet-support:
# the default feature set, built with `--locked`, reporting the chain label
# `swarm-testnet` to light wallets.
#
# The binary keeps upstream's guard that refuses a plaintext gRPC bind on a
# non-private address, so no `no_tls_*` feature is enabled here. The entrypoint
# binds the container's own RFC1918 address instead, which satisfies the guard
# while leaving the listener reachable from caddy by service name. TLS is
# terminated at caddy, which is the only container with public ports.
#
# Build context: deploy/swarm
FROM debian:bookworm-slim

ARG SWARM_UID=10001
ARG SWARM_GID=10001

# hadolint ignore=DL3008
RUN apt-get -o Acquire::Retries=3 update \
    && apt-get -o Acquire::Retries=3 install -y --no-install-recommends \
        ca-certificates \
        libgcc-s1 \
        libstdc++6 \
    && rm -rf /var/lib/apt/lists/*

# The same uid as the zebra image, on purpose: Zebra writes its RPC cookie
# with mode 0600, and matching the owner is what makes it readable here
# without a privileged sidecar chmod-ing a shared file.
RUN groupadd --gid "${SWARM_GID}" swarm \
    && useradd --uid "${SWARM_UID}" --gid "${SWARM_GID}" \
        --home-dir /swarm --no-create-home --shell /usr/sbin/nologin swarm \
    && mkdir -p /swarm/data /swarm/auth /swarm/config \
    && chown -R "${SWARM_UID}:${SWARM_GID}" /swarm

VOLUME ["/swarm/data"]

COPY --chmod=0755 bin/zainod /usr/local/bin/zainod
COPY --chmod=0755 images/zaino/entrypoint.sh /usr/local/bin/swarm-zaino-entrypoint
COPY --chmod=0755 images/zaino/healthcheck.sh /usr/local/bin/swarm-zaino-health

USER swarm
WORKDIR /swarm

# Documentation only: the port is never published, and the listener binds the
# container's own address rather than 0.0.0.0.
EXPOSE 8137

HEALTHCHECK --interval=30s --timeout=10s --start-period=90s --retries=5 \
    CMD ["swarm-zaino-health"]

ENTRYPOINT ["/usr/local/bin/swarm-zaino-entrypoint"]
