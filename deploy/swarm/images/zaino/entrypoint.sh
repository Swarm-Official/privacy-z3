#!/usr/bin/env bash
# Starts the SWARM light-wallet indexer, and keeps it in step with the node's
# rotating RPC cookie.
#
# THE COOKIE PROBLEM
#
# Zebra generates a fresh random RPC cookie on every start and deletes the file
# on shutdown. Zaino reads that file once, when it builds its RPC client, and
# holds the token for the life of the process (see the comment on `rpc_client`
# in zaino-state: the connector it replaced did the same, and re-reading per
# request was deliberately not introduced). So after a node restart a running
# indexer authenticates with a secret that no longer exists, and every call it
# makes gets 401 for as long as it stays up. It does not crash, which is the
# unpleasant part: it looks alive and serves nothing.
#
# THE ANSWER HERE
#
#   1. Both images run as the same uid, so the 0600 cookie Zebra writes into
#      the shared volume is readable here with no privileged sidecar and no
#      loosening of its permissions.
#   2. This script waits for a cookie to exist before starting the indexer, so
#      a cold start or a node restart never produces a config error about a
#      missing file.
#   3. It records the cookie's hash and starts zainod as a CHILD, staying PID 1
#      itself. zainod installs no signal handlers of its own (there is no
#      `tokio::signal` anywhere in the Zaino tree), and the kernel discards
#      SIGTERM sent to a PID 1 that has no handler - so as PID 1 the indexer
#      could be neither restarted from inside nor stopped by `docker stop`,
#      only killed. As a child it takes the default action and dies on SIGTERM.
#   4. A watcher re-hashes the file. When the value changes - or when the file
#      stays missing past a grace period, which is a node that went down and
#      has not come back - it terminates the child. This script then exits
#      non-zero, and `restart: unless-stopped` starts the container again, at
#      which point step 2 picks up the new secret.
#   5. SIGTERM and SIGINT to this script (what `docker stop` sends) are
#      forwarded to the child, so an operator stop is still a clean stop.
#
# The indexer database is a named volume, so a restart costs a reconnect and
# not a reindex. This is bounded and observable: the reason is logged, and a
# restart loop is visible in `docker compose ps`. The alternative - patching
# Zaino to re-read the cookie per request - is a source change to a fork whose
# rule is to change as little as possible.
set -euo pipefail

die() {
    printf 'swarm-zaino: %s\n' "$1" >&2
    exit 1
}

config=/swarm/config/zainod.toml
cookie_file=/swarm/auth/.cookie
grpc_port="${SWARM_ZAINO_GRPC_PORT:-8137}"

[ -r "${config}" ] || die "no readable ${config}; mount the rendered configuration directory"
[ -w /swarm/data ] || die "/swarm/data is not writable by uid $(id -u); check the indexer volume"

# ---------------------------------------------------------------------------
# Listen address
#
# zainod refuses to serve plaintext gRPC on an address that is not private,
# unless it is built with `no_tls_use_unencrypted_traffic`. That guard is worth
# keeping: it is what stops a misconfiguration from putting unencrypted wallet
# traffic on a public interface. Binding the container's own address satisfies
# it, and costs nothing, because Docker's DNS resolves the service name to
# exactly this address for caddy.
# ---------------------------------------------------------------------------
container_ip="$(getent ahostsv4 "$(hostname)" | awk 'NR==1 {print $1}')"
[ -n "${container_ip}" ] || die "cannot resolve this container's own IPv4 address"
case "${container_ip}" in
    10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|127.*) ;;
    *) die "container address ${container_ip} is not RFC1918; zainod would refuse to bind it without TLS" ;;
esac

export ZAINO_GRPC_SETTINGS__LISTEN_ADDRESS="${container_ip}:${grpc_port}"
export ZAINO_VALIDATOR_SETTINGS__VALIDATOR_JSONRPC_LISTEN_ADDRESS="${SWARM_ZEBRA_RPC:-zebra:18232}"
# The leaf key is `validator_cookie_path`, which ends in `path`, so zainod's
# sensitive-key deny-list does not reject it. The secret itself is never an
# environment variable.
export ZAINO_VALIDATOR_SETTINGS__VALIDATOR_COOKIE_PATH="${cookie_file}"

# The health check needs the address that was actually bound.
printf '%s\n' "${ZAINO_GRPC_SETTINGS__LISTEN_ADDRESS}" > /swarm/data/grpc-address

# ---------------------------------------------------------------------------
# Wait for the node's current cookie
# ---------------------------------------------------------------------------
wait_seconds="${SWARM_COOKIE_WAIT_SECONDS:-300}"
deadline=$(( $(date +%s) + wait_seconds ))
until [ -r "${cookie_file}" ] && [ -s "${cookie_file}" ]; do
    [ "$(date +%s)" -lt "${deadline}" ] \
        || die "no readable ${cookie_file} after ${wait_seconds}s; is the node running with cookie auth?"
    sleep 2
done
start_hash="$(sha256sum "${cookie_file}" | cut -d' ' -f1)"
printf 'swarm-zaino: validator cookie fingerprint %s\n' "${start_hash:0:12}" >&2

# ---------------------------------------------------------------------------
# Start the indexer as a child and supervise it
# ---------------------------------------------------------------------------
printf 'swarm-zaino: serving gRPC on %s\n' "${ZAINO_GRPC_SETTINGS__LISTEN_ADDRESS}" >&2
zainod start --config "${config}" "$@" &
indexer_pid=$!

stopping=0
forward() {
    stopping=1
    kill -TERM "${indexer_pid}" 2>/dev/null || true
}
trap forward TERM INT

stop_indexer() {
    kill -TERM "${indexer_pid}" 2>/dev/null || true
    for _ in $(seq 1 "${SWARM_INDEXER_STOP_SECONDS:-25}"); do
        kill -0 "${indexer_pid}" 2>/dev/null || return 0
        sleep 1
    done
    kill -KILL "${indexer_pid}" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Follow the rotation
# ---------------------------------------------------------------------------
poll="${SWARM_COOKIE_POLL_SECONDS:-5}"
missing_grace="${SWARM_COOKIE_MISSING_GRACE_SECONDS:-120}"
missing_since=0
rotated=0

while :; do
    # `wait` returns as soon as a trapped signal arrives, so the sleep is a
    # plain sleep and the poll interval bounds how long a stale token lives.
    sleep "${poll}" &
    wait $! 2>/dev/null || true
    [ "${stopping}" -eq 0 ] || break

    if ! kill -0 "${indexer_pid}" 2>/dev/null; then
        wait "${indexer_pid}" 2>/dev/null || indexer_status=$?
        indexer_status="${indexer_status:-0}"
        printf 'swarm-zaino: zainod exited with status %s\n' "${indexer_status}" >&2
        exit "${indexer_status}"
    fi

    if [ ! -r "${cookie_file}" ] || [ ! -s "${cookie_file}" ]; then
        # Expected and brief while the node restarts; only a long absence
        # means the token held in memory is certainly stale.
        now="$(date +%s)"
        [ "${missing_since}" -ne 0 ] || missing_since="${now}"
        if [ $(( now - missing_since )) -ge "${missing_grace}" ]; then
            printf 'swarm-zaino: validator cookie absent for %ss; restarting to re-authenticate\n' \
                "${missing_grace}" >&2
            rotated=1
            break
        fi
        continue
    fi

    missing_since=0
    current_hash="$(sha256sum "${cookie_file}" 2>/dev/null | cut -d' ' -f1)" || continue
    if [ -n "${current_hash}" ] && [ "${current_hash}" != "${start_hash}" ]; then
        printf 'swarm-zaino: validator cookie rotated (%s -> %s); restarting to re-authenticate\n' \
            "${start_hash:0:12}" "${current_hash:0:12}" >&2
        rotated=1
        break
    fi
done

stop_indexer
wait "${indexer_pid}" 2>/dev/null || true

if [ "${rotated}" -eq 1 ]; then
    # A non-zero exit is what makes `restart: unless-stopped` bring the
    # container back with the new secret.
    exit 75
fi
exit 0
