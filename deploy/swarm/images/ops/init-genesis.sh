#!/usr/bin/env bash
# Puts genesis into the node's database exactly once, and proves it afterwards.
#
# Zebra does not insert a genesis block for a configured testnet the way it does
# for its built-in networks: the database starts genuinely empty and the block
# has to arrive through `submitblock`, once, on a node that already has the
# right consensus parameters loaded.
#
# The "exactly once" guard is `getblockhash 0`, not a marker file. An empty
# database answers it with an error; an initialised one answers with a hash.
# That is a property of the database itself, so it stays correct across
# container recreation, volume restores and a job that was interrupted halfway.
# A reported height of zero is NOT used as the test: height zero is also what a
# chain with only genesis reports.
#
# The job is idempotent: on every later `up` it skips the submission and only
# verifies. It always ends by comparing the node's height-zero hash with the
# manifest, so the indexer never starts against the wrong chain.
set -euo pipefail

die() {
    printf 'swarm-init-genesis: %s\n' "$1" >&2
    exit 1
}

config_dir="${SWARM_CONFIG_DIR:-/swarm/config}"
manifest="${config_dir}/manifest.json"
genesis_file="${config_dir}/genesis.hex"

[ -r "${manifest}" ] || die "no readable ${manifest}"
[ -r "${genesis_file}" ] || die "no readable ${genesis_file}"

expected_hash="$(jq -r '.genesis_hash // empty' "${manifest}")"
[ -n "${expected_hash}" ] || die "manifest has no genesis_hash"
[[ "${expected_hash}" =~ ^[0-9a-f]{64}$ ]] || die "manifest genesis_hash is not a 32-byte hex hash"

network_name="$(jq -r '.network_name // .name // "the configured testnet"' "${manifest}")"

# ---------------------------------------------------------------------------
# Wait for the node's RPC
# ---------------------------------------------------------------------------
wait_seconds="${SWARM_RPC_WAIT_SECONDS:-300}"
deadline=$(( $(date +%s) + wait_seconds ))
until swarm-rpc getinfo >/dev/null 2>&1; do
    [ "$(date +%s)" -lt "${deadline}" ] || die "the node RPC did not answer within ${wait_seconds}s"
    sleep 2
done

genesis_hash_on_node() {
    local response
    response="$(swarm-rpc getblockhash '[0]')" || return 1
    if [ "$(jq -r '.error // "null"' <<<"${response}")" != "null" ]; then
        # An empty database. Not an error here: it is the state this job exists
        # to change.
        printf ''
        return 0
    fi
    jq -r '.result // empty' <<<"${response}"
}

have="$(genesis_hash_on_node)" || die "cannot read height zero from the node"

if [ -z "${have}" ]; then
    printf 'swarm-init-genesis: database is empty; submitting genesis for %s\n' "${network_name}" >&2

    genesis_hex="$(tr -d ' \t\r\n' < "${genesis_file}")"
    [[ "${genesis_hex}" =~ ^[0-9a-f]+$ ]] || die "genesis.hex is not lowercase hex"
    [ $(( ${#genesis_hex} % 2 )) -eq 0 ] || die "genesis.hex has an odd number of hex digits"

    # submitblock is a mutation, so it is never blindly retried: if the
    # response is lost, the reconciliation below is what decides the outcome.
    submit="$(swarm-rpc submitblock "[\"${genesis_hex}\"]" || true)"
    printf 'swarm-init-genesis: submitblock said %s\n' "${submit:-<no response>}" >&2

    have="$(genesis_hash_on_node)" || die "cannot read height zero after submitting genesis"
    [ -n "${have}" ] || die "the node still has no block at height zero; inspect the node log"
fi

if [ "${have}" != "${expected_hash}" ]; then
    die "the node's genesis is ${have}, but the manifest says ${expected_hash};
  this database belongs to a different chain. Do not delete it blindly: either
  point SWARM_CONFIG_DIR at the matching manifest, or remove the chain volume
  deliberately and redeploy."
fi

printf 'swarm-init-genesis: %s genesis confirmed at height 0: %s\n' "${network_name}" "${have}"
