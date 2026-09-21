#!/usr/bin/env bash
# Healthy means: the gRPC listener accepts a TCP connection on the address the
# entrypoint actually bound.
#
# Not 127.0.0.1: the indexer binds the container's own RFC1918 address, because
# that is what satisfies zainod's refusal to serve plaintext gRPC on a
# non-private address. The entrypoint records the address it chose.
#
# A real GetLightdInfo call is the deploy-time check (scripts/healthcheck.sh),
# not this one: a container health check should be cheap enough to run every
# 30 seconds forever.
set -euo pipefail

address_file=/swarm/data/grpc-address
[ -r "${address_file}" ] || exit 1
address="$(cat "${address_file}")"
host="${address%:*}"
port="${address##*:}"

[ -n "${host}" ] && [ -n "${port}" ] || exit 1

timeout 5 bash -c "exec 3<>/dev/tcp/${host}/${port}" 2>/dev/null || exit 1
exit 0
