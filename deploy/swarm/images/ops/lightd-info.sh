#!/usr/bin/env bash
# swarm-lightd-info <target>
#
# Calls CompactTxStreamer/GetLightdInfo and prints the decoded response as JSON.
#
#   swarm-lightd-info h2c://zaino:8137        plaintext, inside the network
#   swarm-lightd-info https://lwd.swarm.green through caddy, over TLS
#
# The same code path serves both, which is the point: what CI can prove over
# h2c and what the server must answer over TLS differ only in the URL.
#
# A unary gRPC request body is a five-byte frame - one compression flag, then a
# big-endian length - around the request message. GetLightdInfo takes Empty, so
# the message is zero bytes and the whole body is five zero bytes.
set -euo pipefail

target="${1:?usage: swarm-lightd-info <h2c://host:port | https://host[:port]>}"
path='/cash.z.wallet.sdk.rpc.CompactTxStreamer/GetLightdInfo'

case "${target}" in
    h2c://*)
        url="http://${target#h2c://}${path}"
        # No TLS and no upgrade dance: speak HTTP/2 from the first byte.
        http_args=(--http2-prior-knowledge)
        ;;
    http://*)
        url="${target}${path}"
        http_args=(--http2-prior-knowledge)
        ;;
    https://*)
        url="${target}${path}"
        # HTTP/2 is negotiated over ALPN; a server that cannot do h2 will not
        # serve gRPC, so failing here is the right answer.
        http_args=(--http2)
        # TEST ONLY. Let's Encrypt's staging certificates are untrusted by
        # design, which is the whole point of testing against them, so a
        # rehearsal needs a way to say "I know". Never set this against the
        # production endpoint: it would turn the identity check into a check
        # that something answered.
        if [ "${SWARM_GRPC_INSECURE:-0}" = "1" ]; then
            printf 'swarm-lightd-info: TLS verification disabled (SWARM_GRPC_INSECURE=1)\n' >&2
            http_args+=(--insecure)
        fi
        ;;
    *)
        printf 'swarm-lightd-info: target must start with h2c://, http:// or https://\n' >&2
        exit 2
        ;;
esac

body="$(mktemp)"
headers="$(mktemp)"
trap 'rm -f "${body}" "${headers}"' EXIT

# shellcheck disable=SC2312
if ! printf '\x00\x00\x00\x00\x00' | curl -sS \
        "${http_args[@]}" \
        --max-time "${SWARM_GRPC_TIMEOUT:-20}" \
        --dump-header "${headers}" \
        --header 'content-type: application/grpc' \
        --header 'te: trailers' \
        --header 'grpc-accept-encoding: identity' \
        --data-binary @- \
        --output "${body}" \
        "${url}"; then
    printf 'swarm-lightd-info: the request to %s failed\n' "${url}" >&2
    exit 1
fi

# gRPC reports its own status in a header or trailer, not in the HTTP status.
status="$(grep -aiE '^grpc-status:' "${headers}" | tail -n 1 | tr -d ' \r' | cut -d: -f2 || true)"
if [ -n "${status}" ] && [ "${status}" != "0" ]; then
    message="$(grep -aiE '^grpc-message:' "${headers}" | tail -n 1 | tr -d '\r' || true)"
    printf 'swarm-lightd-info: server returned grpc-status %s (%s)\n' "${status}" "${message}" >&2
    exit 1
fi

swarm-lightd-decode < "${body}"
