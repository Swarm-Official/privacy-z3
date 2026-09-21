#!/usr/bin/env bash
# Starts the SWARM seed node.
#
# The chain's consensus parameters live entirely in the mounted zebrad.toml,
# which is rendered from the network manifest and is not edited here. This
# script only supplies the things that are properties of *this deployment*:
# where state and the RPC cookie live, which addresses to listen on and
# advertise, and the miner payout. They are passed as ZEBRA_* environment
# overrides, which zebrad layers on top of the file.
#
# Empty values are deliberately unset rather than exported: config-rs treats an
# empty string as a value, so an empty ZEBRA_NETWORK__EXTERNAL_ADDR is a parse
# error rather than "unset".
set -euo pipefail

die() {
    printf 'swarm-zebra: %s\n' "$1" >&2
    exit 1
}

config=/swarm/config/zebrad.toml
[ -r "${config}" ] || die "no readable ${config}; mount the rendered configuration directory"

# A byte-order mark makes zebrad's TOML parser fail with an unhelpful message.
# Catch it here, where the message can say what to do about it.
if [ "$(head -c 3 "${config}" | od -An -tx1 | tr -d ' \n')" = "efbbbf" ]; then
    die "${config} starts with a UTF-8 byte-order mark; re-render it as UTF-8 without a BOM"
fi

[ -w /swarm/state ] || die "/swarm/state is not writable by uid $(id -u); check the chain volume"
[ -w /swarm/auth ] || die "/swarm/auth is not writable by uid $(id -u); check the auth volume"

p2p_port="${SWARM_P2P_PORT:-18233}"
rpc_port="${SWARM_RPC_PORT:-18232}"

export ZEBRA_STATE__CACHE_DIR=/swarm/state
export ZEBRA_NETWORK__LISTEN_ADDR="0.0.0.0:${p2p_port}"

# Reachable only over the compose network: no host port is published for it.
export ZEBRA_RPC__LISTEN_ADDR="0.0.0.0:${rpc_port}"
export ZEBRA_RPC__ENABLE_COOKIE_AUTH=true
# The leaf key is `cookie_dir`, not `cookie`, so zebrad's sensitive-key
# deny-list does not reject it. The cookie secret itself is never an env var.
export ZEBRA_RPC__COOKIE_DIR=/swarm/auth

# Peers dial the address the node advertises, not the one it binds. Without a
# public address Zebra still makes outbound connections but accepts none, so a
# seed node is only a seed once this is set.
if [ -n "${SWARM_PUBLIC_IP:-}" ]; then
    export ZEBRA_NETWORK__EXTERNAL_ADDR="${SWARM_PUBLIC_IP}:${p2p_port}"
else
    printf 'swarm-zebra: SWARM_PUBLIC_IP is unset; this node will not advertise itself to peers\n' >&2
fi

# The always-on baseline miner. One solver thread, by Zebra's design, paying
# the address supplied at deploy time. Without an address there is nothing to
# pay, so the miner stays off rather than failing at startup.
if [ -n "${SWARM_MINER_ADDRESS:-}" ]; then
    export ZEBRA_MINING__MINER_ADDRESS="${SWARM_MINER_ADDRESS}"
    export ZEBRA_MINING__INTERNAL_MINER="${SWARM_INTERNAL_MINER:-true}"
else
    export ZEBRA_MINING__INTERNAL_MINER=false
    printf 'swarm-zebra: SWARM_MINER_ADDRESS is unset; the internal miner stays off\n' >&2
fi

# Block verification uses rayon. The container is capped at about one shared
# vCPU, so an unbounded pool would only add context switching.
export RAYON_NUM_THREADS="${SWARM_RAYON_THREADS:-2}"

# Anything left empty would be read as a value rather than as "unset".
while IFS='=' read -r key value; do
    case "${key}" in
        ZEBRA_*) [ -n "${value}" ] || unset "${key}" ;;
    esac
done < <(env)

printf 'swarm-zebra: starting zebrad with %s\n' "${config}" >&2
exec zebrad -c "${config}" "$@"
