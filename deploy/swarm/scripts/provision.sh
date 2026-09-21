#!/usr/bin/env bash
# Prepare a fresh Ubuntu server to run the SWARM stack. Run as root, over SSH.
#
#   scp -i ~/.ssh/swarm_server_ed25519 provision.sh root@<ip>:/root/
#   ssh -i ~/.ssh/swarm_server_ed25519 root@<ip> 'bash /root/provision.sh'
#
# Idempotent: every step checks the state it wants before changing anything, so
# running it twice is a no-op and running it after a partial failure resumes.
#
# It installs Docker Engine and the compose plugin, creates an unprivileged
# deploy user, makes a swap file, turns on unattended security upgrades, time
# sync and fail2ban for SSH, and configures the firewall.
#
# The firewall is the one dangerous step, so it is last and deliberate: port 22
# is allowed before UFW is enabled, and the script prints a reminder to open a
# second SSH session before closing the one that ran it.
#
# Tested on Ubuntu 24.04 (noble) and 26.04 (resolute). The release codename is
# read from /etc/os-release, never hard-coded, and the script falls back to the
# Ubuntu archive's own docker.io + docker-compose-v2 packages if Docker's
# repository has no release for this codename yet.
set -euo pipefail

SWARM_USER="${SWARM_USER:-swarm}"
SWARM_HOME="${SWARM_HOME:-/opt/swarm}"
SWARM_SWAP_SIZE="${SWARM_SWAP_SIZE:-2G}"
SWARM_SWAPPINESS="${SWARM_SWAPPINESS:-10}"
SWARM_P2P_PORT="${SWARM_P2P_PORT:-18233}"
# Optional: restrict SSH to one address. Empty means "from anywhere", which is
# the safe default for a box whose operator may have a changing address.
SWARM_ADMIN_IP="${SWARM_ADMIN_IP:-}"
# Set to 0 to prepare everything and leave the firewall alone.
SWARM_ENABLE_FIREWALL="${SWARM_ENABLE_FIREWALL:-1}"

log() { printf '\n==> %s\n' "$1"; }
note() { printf '    %s\n' "$1"; }

[ "$(id -u)" -eq 0 ] || { echo 'provision.sh must run as root' >&2; exit 1; }

. /etc/os-release
: "${ID:?/etc/os-release has no ID}"
: "${VERSION_CODENAME:?/etc/os-release has no VERSION_CODENAME}"
[ "${ID}" = "ubuntu" ] || { echo "this script targets Ubuntu; found ${ID}" >&2; exit 1; }
log "Ubuntu ${VERSION_ID:-?} (${VERSION_CODENAME}), kernel $(uname -r), $(nproc) vCPU, $(free -m | awk '/^Mem:/ {print $2}') MB RAM"

export DEBIAN_FRONTEND=noninteractive
APT_OPTS=(-o Acquire::Retries=3 -o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef -qq)

# ---------------------------------------------------------------------------
# 1. Base packages
# ---------------------------------------------------------------------------
log 'Base packages'
apt-get "${APT_OPTS[@]}" update
apt-get "${APT_OPTS[@]}" install -y --no-install-recommends \
    ca-certificates curl gnupg jq ufw fail2ban unattended-upgrades \
    systemd-timesyncd tar gzip

# ---------------------------------------------------------------------------
# 2. Docker Engine + compose plugin
#
# Docker's own repository is preferred; it is the only place the compose v2
# plugin and a current engine are both published for a brand-new Ubuntu. If
# that repository has no release file for this codename, the Ubuntu archive's
# docker.io and docker-compose-v2 are a supported fallback - older, but they
# run this stack. The fallback is announced, never silent.
# ---------------------------------------------------------------------------
log 'Docker Engine'
if docker compose version >/dev/null 2>&1; then
    note "already installed: $(docker --version), $(docker compose version)"
else
    docker_repo="https://download.docker.com/linux/ubuntu"
    if curl -fsSL --max-time 20 -o /dev/null "${docker_repo}/dists/${VERSION_CODENAME}/Release"; then
        note "using Docker's repository for ${VERSION_CODENAME}"
        install -m 0755 -d /etc/apt/keyrings
        if [ ! -s /etc/apt/keyrings/docker.asc ]; then
            curl -fsSL "${docker_repo}/gpg" -o /etc/apt/keyrings/docker.asc
            chmod a+r /etc/apt/keyrings/docker.asc
        fi
        printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] %s %s stable\n' \
            "$(dpkg --print-architecture)" "${docker_repo}" "${VERSION_CODENAME}" \
            > /etc/apt/sources.list.d/docker.list
        apt-get "${APT_OPTS[@]}" update
        apt-get "${APT_OPTS[@]}" install -y \
            docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    else
        note "Docker has no release for ${VERSION_CODENAME}; falling back to the Ubuntu archive"
        apt-get "${APT_OPTS[@]}" install -y docker.io docker-compose-v2
    fi
    systemctl enable --now docker
fi
docker --version
docker compose version

# Bound the daemon's own log growth as well as the stack's. The compose file
# sets per-service limits; this covers anything started outside it.
log 'Docker daemon defaults'
daemon_json=/etc/docker/daemon.json
desired_daemon='{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "5"
  },
  "live-restore": true
}'
if [ ! -f "${daemon_json}" ] || ! diff -q <(printf '%s\n' "${desired_daemon}") "${daemon_json}" >/dev/null 2>&1; then
    mkdir -p /etc/docker
    printf '%s\n' "${desired_daemon}" > "${daemon_json}"
    systemctl restart docker
    note 'wrote /etc/docker/daemon.json and restarted docker'
else
    note 'already current'
fi

# ---------------------------------------------------------------------------
# 3. Deploy user
#
# The stack runs from this account, not root. It is in the docker group, which
# is root-equivalent on this host - that is inherent to Docker and is why the
# account exists at all rather than adding the group to a human login.
# ---------------------------------------------------------------------------
log "Deploy user ${SWARM_USER}"
if id -u "${SWARM_USER}" >/dev/null 2>&1; then
    note 'already exists'
else
    useradd --system --create-home --home-dir "/home/${SWARM_USER}" --shell /bin/bash "${SWARM_USER}"
fi
usermod -aG docker "${SWARM_USER}"
install -d -o "${SWARM_USER}" -g "${SWARM_USER}" -m 0750 "${SWARM_HOME}"
install -d -o "${SWARM_USER}" -g "${SWARM_USER}" -m 0750 "${SWARM_HOME}/config"
install -d -o "${SWARM_USER}" -g "${SWARM_USER}" -m 0750 "${SWARM_HOME}/backups"

# Let the account be reached with the same key that reached root, so an
# operator never has to log in as root again after this script.
if [ -s /root/.ssh/authorized_keys ]; then
    install -d -o "${SWARM_USER}" -g "${SWARM_USER}" -m 0700 "/home/${SWARM_USER}/.ssh"
    install -o "${SWARM_USER}" -g "${SWARM_USER}" -m 0600 \
        /root/.ssh/authorized_keys "/home/${SWARM_USER}/.ssh/authorized_keys"
    note "copied root's authorized_keys to ${SWARM_USER}"
fi

# ---------------------------------------------------------------------------
# 4. Swap
#
# Always, not only when RAM is short: 4 GB with an indexer, a node and a miner
# has no headroom for a transient peak, and the alternative to swapping is the
# OOM killer taking the node down mid-write. Swappiness is low so it is a
# safety net rather than a normal path.
# ---------------------------------------------------------------------------
log "Swap (${SWARM_SWAP_SIZE})"
if swapon --show=NAME --noheadings | grep -q .; then
    note "already active: $(swapon --show=NAME,SIZE --noheadings | tr '\n' ' ')"
else
    if [ ! -f /swapfile ]; then
        fallocate -l "${SWARM_SWAP_SIZE}" /swapfile 2>/dev/null \
            || dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none
    fi
    chmod 0600 /swapfile
    mkswap /swapfile >/dev/null
    swapon /swapfile
    grep -q '^/swapfile ' /etc/fstab || printf '/swapfile none swap sw 0 0\n' >> /etc/fstab
    note 'created and enabled /swapfile'
fi
printf 'vm.swappiness=%s\n' "${SWARM_SWAPPINESS}" > /etc/sysctl.d/60-swarm-swappiness.conf
sysctl -q -w "vm.swappiness=${SWARM_SWAPPINESS}"
note "vm.swappiness=${SWARM_SWAPPINESS}"

# ---------------------------------------------------------------------------
# 5. Time
#
# Block timestamps have to be sane: Zebra checks them against median time past
# and rejects blocks too far in the future, so a drifting clock on the only
# mining node would stall the chain.
# ---------------------------------------------------------------------------
log 'Time synchronisation'
systemctl enable --now systemd-timesyncd >/dev/null 2>&1 || true
timedatectl set-ntp true || true
timedatectl | sed 's/^/    /'

# ---------------------------------------------------------------------------
# 6. Unattended security upgrades
# ---------------------------------------------------------------------------
log 'Unattended security upgrades'
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'CONF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
CONF
cat > /etc/apt/apt.conf.d/52swarm-unattended-upgrades <<'CONF'
// Security updates only. Feature updates to Docker are an operator decision,
// because an engine restart takes the node down.
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};
Unattended-Upgrade::Package-Blacklist {
    "docker-ce";
    "docker-ce-cli";
    "containerd.io";
    "docker.io";
};
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
// Never reboot by itself: a reboot is a chain outage, so it is scheduled.
Unattended-Upgrade::Automatic-Reboot "false";
CONF
systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true
note 'security-only, docker packages held, no automatic reboot'

# ---------------------------------------------------------------------------
# 7. fail2ban for SSH
# ---------------------------------------------------------------------------
log 'fail2ban'
cat > /etc/fail2ban/jail.d/swarm-sshd.local <<'CONF'
[sshd]
enabled = true
# systemd's journal, not /var/log/auth.log, which Ubuntu no longer writes by
# default.
backend = systemd
maxretry = 5
findtime = 10m
bantime = 1h
CONF
systemctl enable --now fail2ban >/dev/null 2>&1 || true
systemctl is-active fail2ban | sed 's/^/    fail2ban: /'

# ---------------------------------------------------------------------------
# 8. Firewall
#
# Last, and with SSH allowed before anything is enabled. UFW's default-deny
# applies to new inbound connections only, so the session running this script
# survives - but verify a second session anyway before closing this one.
#
# Note what is NOT here: the node's RPC and the indexer's gRPC have no rule,
# because neither is published to the host at all. Docker's own iptables rules
# bypass UFW's INPUT chain for published ports, which is exactly why the stack
# publishes only 18233, 80 and 443 and nothing else.
# ---------------------------------------------------------------------------
log 'Firewall'
ufw --force reset >/dev/null
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
if [ -n "${SWARM_ADMIN_IP}" ]; then
    ufw allow from "${SWARM_ADMIN_IP}" to any port 22 proto tcp comment 'ssh (admin)' >/dev/null
    note "ssh restricted to ${SWARM_ADMIN_IP}"
else
    ufw allow 22/tcp comment 'ssh' >/dev/null
    note 'ssh open to any address (set SWARM_ADMIN_IP to restrict)'
fi
ufw allow 80/tcp comment 'http (ACME + redirect)' >/dev/null
ufw allow 443/tcp comment 'https (light-wallet gRPC)' >/dev/null
ufw allow "${SWARM_P2P_PORT}/tcp" comment 'swarm p2p' >/dev/null

if [ "${SWARM_ENABLE_FIREWALL}" = "1" ]; then
    ufw --force enable >/dev/null
    systemctl enable ufw >/dev/null 2>&1 || true
else
    note 'rules written, firewall left disabled (SWARM_ENABLE_FIREWALL=0)'
fi
ufw status verbose | sed 's/^/    /'

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
log 'Provisioned'
cat <<SUMMARY
    deploy user      ${SWARM_USER} (in the docker group)
    stack directory  ${SWARM_HOME}
    docker           $(docker --version)
    compose          $(docker compose version --short 2>/dev/null || docker compose version)
    swap             $(swapon --show=NAME,SIZE --noheadings | tr '\n' ' ')
    open ports       22, 80, 443, ${SWARM_P2P_PORT}
    listening now    $(ss -tlnH 2>/dev/null | awk '{print $4}' | sort -u | tr '\n' ' ')

    BEFORE YOU CLOSE THIS SESSION: open a second one and confirm it connects.
    The firewall is active and a mistake in the SSH rule is only visible on a
    new connection.

    Next: run scripts/deploy.sh from the workstation.
SUMMARY
