#!/usr/bin/env bash
# swarm-rpc <method> [json-params-array]
#
# One authenticated JSON-RPC call to the node, printing the raw response on
# stdout. The cookie is read fresh on every call, so this never holds a secret
# that the node has since rotated away.
#
# Exit status is curl's: a transport failure is a failure here. A JSON-RPC
# *error* object is a successful call with an error result, and the caller
# decides what that means - "height zero does not exist" is the normal state of
# an empty database, not a fault.
set -euo pipefail

method="${1:?usage: swarm-rpc <method> [params-json]}"
params="${2:-[]}"

cookie_file="${SWARM_COOKIE_FILE:-/swarm/auth/.cookie}"
rpc_address="${SWARM_ZEBRA_RPC:-zebra:18232}"

[ -s "${cookie_file}" ] || {
    printf 'swarm-rpc: no readable cookie at %s\n' "${cookie_file}" >&2
    exit 69
}

# The file holds exactly `__cookie__:<secret>`: already curl's user:password
# form, and the secret is base64, so it contains no colon of its own.
cookie="$(cat "${cookie_file}")"

# --data-binary with @- keeps the payload off the process table.
printf '{"jsonrpc":"2.0","id":"swarm-ops","method":"%s","params":%s}' "${method}" "${params}" \
    | curl -sS --max-time "${SWARM_RPC_TIMEOUT:-30}" \
        --user "${cookie}" \
        --header 'content-type: application/json' \
        --data-binary @- \
        "http://${rpc_address}"
