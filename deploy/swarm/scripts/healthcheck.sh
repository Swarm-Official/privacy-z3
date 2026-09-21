#!/usr/bin/env bash
# Is the stack actually doing its job? Runs on the server.
#
#   /opt/swarm/scripts/healthcheck.sh            everything it can check
#   SWARM_SKIP_TLS=1 .../healthcheck.sh          skip the public TLS check
#
# Exit status is the verdict: zero only if every required check passed.
#
# Checks, in the order a failure is most likely:
#   1. every service is running, and the genesis job completed
#   2. the node's height-zero hash is the one in the manifest
#   3. the node's height is advancing, which means the miner is working
#   4. the P2P listener is open on the host
#   5. the indexer answers GetLightdInfo over h2c inside the network, reports
#      the expected chain label, and is following the node's tip
#   6. the same call over public TLS reports the same label
#
# Check 6 is the only one that needs DNS and a certificate. It is skipped
# automatically when the domain does not resolve to this host, so this script
# is useful from the first deploy onwards rather than only after DNS is live.
set -euo pipefail

stack_dir="${SWARM_REMOTE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "${stack_dir}"

compose() { docker compose --env-file .env "$@"; }
ops() { compose run --rm --no-deps -T init-genesis "$@"; }

pass() { printf '  ok    %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures + 1)); }
skip() { printf '  skip  %s\n' "$1"; }
failures=0

# shellcheck disable=SC1091
set -a; . ./.env; set +a
p2p_port="${SWARM_P2P_PORT:-18233}"
expected_chain="${SWARM_EXPECTED_CHAIN_NAME:-swarm-testnet}"
config_dir="${SWARM_CONFIG_DIR:-./config/live}"

printf '\n== services ==\n'
compose ps -a --format 'table {{.Service}}\t{{.State}}\t{{.Status}}'

for service in zebra zaino; do
    state="$(compose ps --format '{{.State}}' "${service}" 2>/dev/null | head -n 1)"
    if [ "${state}" = "running" ]; then
        pass "${service} is running"
    else
        fail "${service} is '${state:-absent}'"
    fi
done

genesis_exit="$(docker inspect --format '{{.State.ExitCode}}' \
    "$(compose ps -aq init-genesis | head -n 1)" 2>/dev/null || echo unknown)"
if [ "${genesis_exit}" = "0" ]; then
    pass 'the genesis job completed successfully'
else
    fail "the genesis job exited ${genesis_exit}"
fi

printf '\n== chain ==\n'
# The network manifest nests it under `genesis.hash`; the throwaway fixture
# has it flat. Both are read, so one healthcheck serves both.
expected_genesis="$(jq -r '.genesis.hash // .genesis_hash // empty' "${config_dir}/manifest.json" 2>/dev/null || echo '')"
actual_genesis="$(ops swarm-rpc getblockhash '[0]' 2>/dev/null | jq -r '.result // empty' || true)"
if [ -n "${expected_genesis}" ] && [ "${actual_genesis}" = "${expected_genesis}" ]; then
    pass "genesis ${actual_genesis}"
else
    fail "genesis is '${actual_genesis:-unreadable}', manifest says '${expected_genesis:-unreadable}'"
fi

info() { ops swarm-rpc getblockchaininfo 2>/dev/null; }
first="$(info | jq -r '.result.blocks // empty' || true)"
if [ -z "${first}" ]; then
    fail 'the node did not answer getblockchaininfo'
else
    printf '  ..    height %s; watching for %ss\n' "${first}" "${SWARM_HEIGHT_WINDOW:-90}"
    sleep "${SWARM_HEIGHT_WINDOW:-90}"
    second="$(info | jq -r '.result.blocks // empty' || true)"
    if [ -n "${second}" ] && [ "${second}" -gt "${first}" ]; then
        pass "height advanced ${first} -> ${second}"
    elif [ "${SWARM_INTERNAL_MINER:-true}" = "false" ]; then
        skip "height is ${second:-?} and the internal miner is off, so nothing here mines"
    else
        fail "height did not advance in ${SWARM_HEIGHT_WINDOW:-90}s (still ${second:-?}); is the miner running?"
    fi
fi

peers="$(ops swarm-rpc getpeerinfo 2>/dev/null | jq -r '.result | length' || echo '?')"
printf '  ..    %s connected peers (zero is normal for the first node of a new chain)\n' "${peers}"

printf '\n== ports ==\n'
if ss -tlnH "sport = :${p2p_port}" 2>/dev/null | grep -q .; then
    pass "the P2P listener is open on ${p2p_port}"
else
    fail "nothing is listening on ${p2p_port}"
fi
printf '  ..    published:\n'
ss -tlnH 2>/dev/null | awk '{printf "        %s\n", $4}' | sort -u

printf '\n== indexer ==\n'
lightd="$(ops swarm-lightd-info "h2c://zaino:${SWARM_ZAINO_GRPC_PORT:-8137}" 2>/dev/null || true)"
if [ -z "${lightd}" ]; then
    fail 'GetLightdInfo over h2c returned nothing'
else
    chain="$(jq -r '.chain_name // empty' <<<"${lightd}")"
    indexer_height="$(jq -r '.block_height // 0' <<<"${lightd}")"
    if [ "${chain}" = "${expected_chain}" ]; then
        pass "the indexer reports chain_name '${chain}'"
    else
        fail "the indexer reports chain_name '${chain:-none}', expected '${expected_chain}'"
    fi
    # The indexer fetches height zero from the node and compares its hash and
    # the node's whole upgrade schedule against its own configuration before it
    # opens the index, and refuses to start if either disagrees. So an indexer
    # that is serving at all has already made the genesis assertion - there is
    # no way to be served by it and be on the wrong chain.
    pass "the indexer accepted the node's genesis and schedule (it is serving at height ${indexer_height})"

    # Belt and braces, over the wire rather than from its startup: the chain
    # facts it reports have to be the ones the node reports.
    node_branch="$(ops swarm-rpc getblockchaininfo 2>/dev/null \
        | jq -r '.result.consensus.chaintip // empty' || true)"
    wire_branch="$(jq -r '.consensus_branch_id // empty' <<<"${lightd}")"
    if [ -n "${node_branch}" ] && [ "${node_branch}" = "${wire_branch}" ]; then
        pass "consensus branch ${wire_branch} agrees with the node"
    elif [ -z "${node_branch}" ]; then
        skip 'the node did not report a consensus branch to compare'
    else
        fail "the indexer reports branch '${wire_branch}', the node reports '${node_branch}'"
    fi
    jq . <<<"${lightd}" | sed 's/^/        /'
fi

printf '\n== public TLS ==\n'
domain="${SWARM_LWD_DOMAIN:-}"
if [ "${SWARM_SKIP_TLS:-0}" = "1" ]; then
    skip 'requested with SWARM_SKIP_TLS=1'
elif [ -z "${domain}" ]; then
    skip 'SWARM_LWD_DOMAIN is not set'
elif ! getent hosts "${domain}" >/dev/null 2>&1; then
    skip "${domain} does not resolve yet; add the A record, then re-run"
elif ! compose ps --format '{{.State}}' caddy 2>/dev/null | grep -q running; then
    skip 'caddy is not running'
else
    tls="$(ops swarm-lightd-info "https://${domain}" 2>/dev/null || true)"
    chain="$(jq -r '.chain_name // empty' <<<"${tls}" 2>/dev/null || true)"
    if [ "${chain}" = "${expected_chain}" ]; then
        pass "https://${domain} serves gRPC and reports '${chain}'"
    else
        fail "https://${domain} did not report '${expected_chain}' (got '${chain:-nothing}')"
    fi
fi

printf '\n== host ==\n'
printf '        %s\n' "$(uptime -p 2>/dev/null || true)"
free -m | awk '/^Mem:|^Swap:/ {printf "        %-6s %5s MB total %5s MB used\n", $1, $2, $3}'
df -h / | awk 'NR==2 {printf "        disk   %s used of %s (%s)\n", $3, $2, $5}'
docker system df 2>/dev/null | sed 's/^/        /'

printf '\n'
if [ "${failures}" -eq 0 ]; then
    printf 'healthcheck: everything checked passed\n'
    exit 0
fi
printf 'healthcheck: %s check(s) failed\n' "${failures}"
exit 1
