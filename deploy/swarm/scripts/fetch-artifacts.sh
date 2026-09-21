#!/usr/bin/env bash
# Bring CI artifacts down to the workstation, verified. Runs on the workstation.
#
#   scripts/fetch-artifacts.sh --images            the images the server loads
#   scripts/fetch-artifacts.sh --binaries          the two raw binaries
#
# Artifacts travel CI -> workstation -> server. There is no registry and no
# GitHub release in the path, on purpose: nothing this project builds is
# published anywhere until it has been reviewed.
#
# Needs the GitHub CLI, authenticated (`gh auth status`).
set -euo pipefail
export MSYS_NO_PATHCONV=1

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
stack_dir="$(cd "${here}/.." && pwd)"

OUT="${stack_dir}/dist"
WHAT="images"
Z3_REPO="${SWARM_Z3_REPO:-brs-holding/privacy-z3}"
ZEBRA_REPO="${SWARM_ZEBRA_REPO:-brs-holding/privacy-zebra}"
ZAINO_REPO="${SWARM_ZAINO_REPO:-brs-holding/privacy-zaino}"
RUN_ID=""

die() { printf 'fetch-artifacts: %s\n' "$1" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --images) WHAT="images"; shift ;;
        --binaries) WHAT="binaries"; shift ;;
        --run) RUN_ID="${2:?}"; shift 2 ;;
        --out) OUT="${2:?}"; shift 2 ;;
        -h|--help)
            sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) die "unknown option $1" ;;
    esac
done

command -v gh >/dev/null || die 'the GitHub CLI is not on PATH'
gh auth status >/dev/null 2>&1 || die 'the GitHub CLI is not authenticated'

mkdir -p "${OUT}"

latest_run() {
    local repo="$1" workflow="$2"
    gh run list -R "${repo}" --workflow "${workflow}" --status success \
        --limit 1 --json databaseId --jq '.[0].databaseId'
}

case "${WHAT}" in
images)
    # The stack workflow builds the images from the two binaries and exports
    # them with `docker save`, so this is the one artifact a deploy needs.
    run="${RUN_ID:-$(latest_run "${Z3_REPO}" 'SWARM server stack')}"
    [ -n "${run}" ] || die "no successful 'SWARM server stack' run in ${Z3_REPO}"
    printf 'downloading images from %s run %s\n' "${Z3_REPO}" "${run}"
    gh run download "${run}" -R "${Z3_REPO}" -n swarm-images-x86_64-linux -D "${OUT}"
    ;;

binaries)
    # The fallback path: raw binaries, for building the copy-only images on
    # the server when an image artifact is not to hand.
    zebra_run="${RUN_ID:-$(latest_run "${ZEBRA_REPO}" 'SWARM native binaries')}"
    [ -n "${zebra_run}" ] || die "no successful 'SWARM native binaries' run in ${ZEBRA_REPO}"
    zaino_run="$(latest_run "${ZAINO_REPO}" 'SWARM zainod binary')"
    [ -n "${zaino_run}" ] || die "no successful 'SWARM zainod binary' run in ${ZAINO_REPO}"

    work="$(mktemp -d)"
    trap 'rm -rf "${work}"' EXIT

    printf 'downloading zebrad from %s run %s\n' "${ZEBRA_REPO}" "${zebra_run}"
    gh run download "${zebra_run}" -R "${ZEBRA_REPO}" \
        -n swarm-zebrad-x86_64-unknown-linux-gnu -D "${work}/zebra"
    printf 'downloading zainod from %s run %s\n' "${ZAINO_REPO}" "${zaino_run}"
    gh run download "${zaino_run}" -R "${ZAINO_REPO}" \
        -n swarm-zainod-x86_64-unknown-linux-gnu -D "${work}/zaino"

    mkdir -p "${OUT}/bin"
    for component in zebra zaino; do
        ( cd "${work}/${component}" && sha256sum -c SHA256SUMS ) \
            || die "${component}: the archive does not match its SHA256SUMS"
        archive="$(find "${work}/${component}" -name '*.tar.gz' | head -n 1)"
        [ -n "${archive}" ] || die "${component}: no tarball in the artifact"
        tar -xzf "${archive}" -C "${OUT}/bin"
    done
    chmod 0755 "${OUT}/bin/zebrad" "${OUT}/bin/zainod"
    printf '\n'
    ( cd "${OUT}/bin" && sha256sum zebrad zainod )
    ;;
esac

printf '\nin %s:\n' "${OUT}"
ls -lh "${OUT}" | sed 's/^/  /'
