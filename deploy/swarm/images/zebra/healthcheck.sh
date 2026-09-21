#!/usr/bin/env bash
# Healthy means: the RPC server answers an authenticated getblockchaininfo.
#
# Not "has peers" and not "is synced". This is the first node of a new chain,
# so it legitimately has zero peers for a while, and Zebra considers every
# testnet node synced immediately. Requiring either would keep the container
# unhealthy forever and stop the indexer from ever starting.
set -euo pipefail

cookie_file=/swarm/auth/.cookie
rpc_port="${SWARM_RPC_PORT:-18232}"

# The cookie file holds exactly `__cookie__:<secret>`, which is already the
# user:password form curl wants, and the secret is base64 so it has no colon.
[ -s "${cookie_file}" ] || exit 1
cookie="$(cat "${cookie_file}")"

response="$(curl -sS --max-time 8 --user "${cookie}" \
    --header 'content-type: application/json' \
    --data '{"jsonrpc":"2.0","id":"swarm-health","method":"getblockchaininfo","params":[]}' \
    "http://127.0.0.1:${rpc_port}")" || exit 1

case "${response}" in
    *'"bestblockhash"'*) exit 0 ;;
    *) printf 'swarm-zebra-health: unexpected RPC response: %s\n' "${response}" >&2; exit 1 ;;
esac
