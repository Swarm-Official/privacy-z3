#!/usr/bin/env bash
# Deploy the SWARM stack from a workstation to a provisioned server.
#
#   scripts/deploy.sh --host 203.0.113.10 \
#       --images ../../dist --config ./config/live --env ./.env
#
# Nothing is compiled or built from source on the server. The images are built
# in CI from the prebuilt binaries, exported with `docker save`, uploaded here
# and installed with `docker load`. `--binaries` is a documented fallback that
# builds the (copy-only) images on the server instead, for when a CI artifact
# is not to hand.
#
# Safe to re-run: uploading is idempotent, `docker compose up` converges, and
# the genesis job submits a block only into a database that has none.
#
# Runs from Git Bash on Windows as well as from Linux. MSYS_NO_PATHCONV stops
# Git Bash rewriting remote absolute paths into Windows ones, and every remote
# command is fed to `bash -s` on stdin rather than passed as an argument, for
# the same reason.
set -euo pipefail
export MSYS_NO_PATHCONV=1

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
stack_dir="$(cd "${here}/.." && pwd)"

SSH_HOST=""
SSH_USER="root"
SSH_KEY="${SWARM_SSH_KEY:-${HOME}/.ssh/swarm_server_ed25519}"
SSH_PORT=22
REMOTE_DIR="${SWARM_REMOTE_DIR:-/opt/swarm}"
IMAGES_DIR=""
BINARIES_DIR=""
CONFIG_DIR="${stack_dir}/config/live"
ENV_FILE="${stack_dir}/.env"
EXPLORER_IMAGE_TAR=""
COMPOSE_PROFILES=""
START=1
HEALTH=1

usage() {
    sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    cat <<'OPTIONS'

Options:
  --host <ip|name>        server to deploy to                      (required)
  --user <name>           ssh user                                 (default: root)
  --key <path>            ssh private key       (default: ~/.ssh/swarm_server_ed25519)
  --port <n>              ssh port                                 (default: 22)
  --remote-dir <path>     stack directory on the server            (default: /opt/swarm)
  --images <dir>          directory of docker save tarballs        (preferred)
  --binaries <dir>        directory holding zebrad and zainod      (fallback: builds on the server)
  --config <dir>          rendered configuration to upload         (default: ./config/live)
  --env <file>            .env to upload                           (default: ./.env)
  --explorer-image <tar>  explorer image tarball to docker load
  --profile <name>        extra compose profile to start           (e.g. explorer)
  --no-start              upload and load only, do not start
  --no-health             skip the health checks
OPTIONS
}

die() { printf 'deploy: %s\n' "$1" >&2; exit 1; }
log() { printf '\n==> %s\n' "$1"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --host) SSH_HOST="${2:?}"; shift 2 ;;
        --user) SSH_USER="${2:?}"; shift 2 ;;
        --key) SSH_KEY="${2:?}"; shift 2 ;;
        --port) SSH_PORT="${2:?}"; shift 2 ;;
        --remote-dir) REMOTE_DIR="${2:?}"; shift 2 ;;
        --images) IMAGES_DIR="${2:?}"; shift 2 ;;
        --binaries) BINARIES_DIR="${2:?}"; shift 2 ;;
        --config) CONFIG_DIR="${2:?}"; shift 2 ;;
        --env) ENV_FILE="${2:?}"; shift 2 ;;
        --explorer-image) EXPLORER_IMAGE_TAR="${2:?}"; shift 2 ;;
        --profile) COMPOSE_PROFILES="${2:?}"; shift 2 ;;
        --no-start) START=0; shift ;;
        --no-health) HEALTH=0; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "unknown option $1" ;;
    esac
done

[ -n "${SSH_HOST}" ] || { usage >&2; die '--host is required'; }
[ -r "${SSH_KEY}" ] || die "no readable ssh key at ${SSH_KEY}"
[ -d "${CONFIG_DIR}" ] || die "no configuration directory at ${CONFIG_DIR}"
[ -r "${ENV_FILE}" ] || die "no .env at ${ENV_FILE} (copy .env.example and fill it in)"

for required in zebrad.toml zainod.toml genesis.hex manifest.json; do
    [ -r "${CONFIG_DIR}/${required}" ] || die "${CONFIG_DIR} has no ${required}"
done

if [ -z "${IMAGES_DIR}" ] && [ -z "${BINARIES_DIR}" ]; then
    die 'one of --images (preferred) or --binaries is required'
fi
if [ -n "${IMAGES_DIR}" ] && [ -n "${BINARIES_DIR}" ]; then
    die '--images and --binaries are alternatives; pick one'
fi

# The private key never leaves the workstation and is never printed: it is only
# ever named on ssh's command line.
SSH_OPTS=(-i "${SSH_KEY}" -p "${SSH_PORT}" -o IdentitiesOnly=yes -o BatchMode=yes
          -o StrictHostKeyChecking=accept-new -o ConnectTimeout=20)
TARGET="${SSH_USER}@${SSH_HOST}"

remote() { ssh "${SSH_OPTS[@]}" "${TARGET}" "bash -s" ; }
remote_env() { ssh "${SSH_OPTS[@]}" "${TARGET}" "env $* bash -s" ; }

# ---------------------------------------------------------------------------
log "Checking ${TARGET}"
# ---------------------------------------------------------------------------
remote <<'REMOTE'
set -euo pipefail
. /etc/os-release
printf 'host     %s\n' "$(hostname)"
printf 'os       %s %s (%s)\n' "${NAME}" "${VERSION_ID:-?}" "${VERSION_CODENAME:-?}"
printf 'kernel   %s\n' "$(uname -r)"
printf 'cpu      %s vCPU\n' "$(nproc)"
printf 'memory   %s MB\n' "$(free -m | awk '/^Mem:/ {print $2}')"
printf 'disk     %s free on /\n' "$(df -h / | awk 'NR==2 {print $4}')"
command -v docker >/dev/null || { echo 'docker is not installed; run provision.sh first' >&2; exit 1; }
docker compose version >/dev/null || { echo 'the docker compose plugin is missing; run provision.sh first' >&2; exit 1; }
printf 'docker   %s\n' "$(docker --version)"
REMOTE

# ---------------------------------------------------------------------------
log 'Staging the upload'
# ---------------------------------------------------------------------------
stage="$(mktemp -d)"
trap 'rm -rf "${stage}"' EXIT

mkdir -p "${stage}/config/live" "${stage}/images" "${stage}/scripts"
cp "${stack_dir}/docker-compose.yml" "${stack_dir}/Caddyfile" "${stage}/"
cp -a "${stack_dir}/images/." "${stage}/images/"
cp -a "${stack_dir}/scripts/." "${stage}/scripts/"
cp -a "${CONFIG_DIR}/." "${stage}/config/live/"
cp "${ENV_FILE}" "${stage}/.env"
if [ -n "${BINARIES_DIR}" ]; then
    mkdir -p "${stage}/bin"
    for binary in zebrad zainod; do
        [ -r "${BINARIES_DIR}/${binary}" ] || die "${BINARIES_DIR} has no ${binary}"
        cp "${BINARIES_DIR}/${binary}" "${stage}/bin/${binary}"
        chmod 0755 "${stage}/bin/${binary}"
    done
    printf '    binaries: %s\n' "$(cd "${stage}/bin" && sha256sum zebrad zainod | tr '\n' ' ')"
fi

# Windows editors and PowerShell redirection leave CRLF and byte-order marks
# behind. A BOM makes Zebra's TOML parser fail, and CRLF breaks a shell
# script's shebang line, so every text file is normalised on the way out.
normalised=0
while IFS= read -r -d '' file; do
    case "${file}" in
        */bin/*) continue ;;
    esac
    if LC_ALL=C grep -qIl . "${file}" 2>/dev/null; then
        python - "${file}" <<'PY'
import sys
path = sys.argv[1]
with open(path, 'rb') as handle:
    data = handle.read()
cleaned = data.replace(b'\r\n', b'\n')
if cleaned.startswith(b'\xef\xbb\xbf'):
    cleaned = cleaned[3:]
if cleaned != data:
    with open(path, 'wb') as handle:
        handle.write(cleaned)
    print(path)
PY
        normalised=$((normalised + 1))
    fi
done < <(find "${stage}" -type f -print0)
printf '    checked %s text files for CRLF and byte-order marks\n' "${normalised}"

# ---------------------------------------------------------------------------
log "Uploading to ${REMOTE_DIR}"
# ---------------------------------------------------------------------------
remote_env "SWARM_REMOTE_DIR=${REMOTE_DIR}" <<'REMOTE'
set -euo pipefail
mkdir -p "${SWARM_REMOTE_DIR}"
REMOTE

tar -czf - -C "${stage}" . \
    | ssh "${SSH_OPTS[@]}" "${TARGET}" "env SWARM_REMOTE_DIR=${REMOTE_DIR} bash -s" <<'REMOTE'
set -euo pipefail
tar -xzf - -C "${SWARM_REMOTE_DIR}"
chmod 0600 "${SWARM_REMOTE_DIR}/.env"
find "${SWARM_REMOTE_DIR}/scripts" -type f -exec chmod 0755 {} +
find "${SWARM_REMOTE_DIR}/images" -name '*.sh' -exec chmod 0755 {} +
[ -d "${SWARM_REMOTE_DIR}/bin" ] && chmod 0755 "${SWARM_REMOTE_DIR}"/bin/* || true
printf 'uploaded:\n'
ls -la "${SWARM_REMOTE_DIR}"
REMOTE

# ---------------------------------------------------------------------------
if [ -n "${IMAGES_DIR}" ]; then
    log 'Installing the images'
    [ -d "${IMAGES_DIR}" ] || die "no image directory at ${IMAGES_DIR}"
    if [ -r "${IMAGES_DIR}/SHA256SUMS" ]; then
        printf '    verifying SHA256SUMS\n'
        ( cd "${IMAGES_DIR}" && sha256sum -c SHA256SUMS ) || die 'an image tarball does not match SHA256SUMS'
    else
        printf '    WARNING: no SHA256SUMS beside the image tarballs\n'
    fi
    found=0
    for tarball in "${IMAGES_DIR}"/swarm-*.tar.gz "${IMAGES_DIR}"/swarm-*.tar; do
        [ -r "${tarball}" ] || continue
        found=1
        printf '    %s (%s)\n' "$(basename "${tarball}")" "$(du -h "${tarball}" | cut -f1)"
        # Streamed, not staged: the server's disk never holds a second copy of
        # the tarball, and `docker load` unpacks gzip itself.
        ssh "${SSH_OPTS[@]}" "${TARGET}" 'docker load' < "${tarball}" \
            || die "docker load failed for $(basename "${tarball}")"
    done
    [ "${found}" -eq 1 ] || die "${IMAGES_DIR} holds no swarm-*.tar.gz image tarballs"
fi

if [ -n "${EXPLORER_IMAGE_TAR}" ]; then
    log 'Installing the explorer image'
    [ -r "${EXPLORER_IMAGE_TAR}" ] || die "no readable ${EXPLORER_IMAGE_TAR}"
    ssh "${SSH_OPTS[@]}" "${TARGET}" 'docker load' < "${EXPLORER_IMAGE_TAR}"
fi

if [ -n "${BINARIES_DIR}" ]; then
    log 'Building the images on the server (fallback path)'
    printf '    these are copy-only images: no compiler, no source, no network fetch beyond apt\n'
    remote_env "SWARM_REMOTE_DIR=${REMOTE_DIR}" <<'REMOTE'
set -euo pipefail
cd "${SWARM_REMOTE_DIR}"
docker compose --env-file .env build zebra zaino init-genesis
REMOTE
fi

if [ "${START}" -eq 0 ]; then
    log 'Uploaded and loaded; not starting (--no-start)'
    exit 0
fi

# ---------------------------------------------------------------------------
log 'Starting the stack'
# ---------------------------------------------------------------------------
remote_env "SWARM_REMOTE_DIR=${REMOTE_DIR}" "SWARM_PROFILES=${COMPOSE_PROFILES}" <<'REMOTE'
set -euo pipefail
cd "${SWARM_REMOTE_DIR}"
profile_args=()
[ -n "${SWARM_PROFILES}" ] && profile_args=(--profile "${SWARM_PROFILES}")

# `--wait` blocks on the health checks and on the genesis job completing
# successfully, so a failure here is a failure to deploy, not a surprise later.
docker compose --env-file .env "${profile_args[@]}" up -d --wait --wait-timeout 600

echo '--- services ---'
docker compose --env-file .env "${profile_args[@]}" ps -a

echo '--- genesis job ---'
docker compose --env-file .env logs --no-color --tail 20 init-genesis

# Disk hygiene: the previous images become untagged on every update, and a
# 96 GB disk that also holds a chain should not accumulate them.
echo '--- pruning ---'
docker image prune -f
docker builder prune -f 2>/dev/null || true
REMOTE

if [ "${HEALTH}" -eq 1 ]; then
    log 'Health checks'
    ssh "${SSH_OPTS[@]}" "${TARGET}" \
        "env SWARM_REMOTE_DIR=${REMOTE_DIR} bash ${REMOTE_DIR}/scripts/healthcheck.sh" \
        || die 'the stack started but did not pass its health checks; see the output above'

    # The one check that has to come from outside the server: is the P2P port
    # actually reachable across the internet, firewall and all?
    log 'P2P reachability from this workstation'
    if timeout 15 bash -c ": < /dev/tcp/${SSH_HOST}/$(grep -E '^SWARM_P2P_PORT=' "${ENV_FILE}" | cut -d= -f2 | tr -d '\r' || echo 18233)" 2>/dev/null; then
        printf '    the P2P port accepts connections from here\n'
    else
        printf '    WARNING: the P2P port did not accept a connection from this workstation.\n'
        printf '    Check the provider firewall and `ufw status` on the server.\n'
    fi
fi

log 'Done'
cat <<SUMMARY
    stack      ${REMOTE_DIR} on ${TARGET}
    status     ssh ${TARGET} '${REMOTE_DIR}/scripts/swarm-stack status'
    logs       ssh ${TARGET} '${REMOTE_DIR}/scripts/swarm-stack logs zebra'
SUMMARY
