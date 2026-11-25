#!/usr/bin/env bash
# System-level prerequisites that need root (Ubuntu/Debian, incl. WSL2). Run it yourself:
#   sudo bash bootstrap/scripts/install-system.sh
# Installs: make, jq, yamllint, docker engine (docker.io) and sets inotify limits persistently.
# CLI binaries (kind, kubectl, helm, ...) are installed WITHOUT root by install-tools.sh.
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "run with sudo: sudo bash $0" >&2; exit 1; }
TARGET_USER=${SUDO_USER:-}
[[ -n "$TARGET_USER" && "$TARGET_USER" != root ]] || { echo "run via sudo from your normal user (SUDO_USER is empty)" >&2; exit 1; }

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl git make jq python3 yamllint

if ! command -v docker >/dev/null 2>&1; then
  # capture first: `apt-cache | grep -q` under pipefail fails with SIGPIPE when grep exits early
  docker_candidate=$(apt-cache policy docker.io | awk '/Candidate:/ {print $2}')
  if [[ -n "$docker_candidate" && "$docker_candidate" != "(none)" ]]; then
    apt-get install -y --no-install-recommends docker.io
  else
    echo "docker.io has no apt candidate on this release." >&2
    echo "Install Docker Engine manually (https://docs.docker.com/engine/install/) and re-run this script." >&2
    exit 2
  fi
fi

# docker group (re-login / 'wsl --shutdown' needed for the group to apply)
getent group docker >/dev/null || groupadd docker
usermod -aG docker "$TARGET_USER"

# systemd hosts (WSL2 with systemd=true, regular Linux)
if [[ -d /run/systemd/system ]]; then
  systemctl enable --now docker
else
  echo "systemd not running: start the daemon manually (sudo service docker start)" >&2
fi

# inotify limits required by multi-node kind (SPEC §2.1, ARCHITECTURE §15-7)
cat > /etc/sysctl.d/99-kind-inotify.conf <<'SYSCTL'
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 512
SYSCTL
sysctl --system >/dev/null
echo "inotify: watches=$(cat /proc/sys/fs/inotify/max_user_watches) instances=$(cat /proc/sys/fs/inotify/max_user_instances)"

echo
echo "Done. Open a NEW shell (or run 'newgrp docker') so '$TARGET_USER' picks up the docker group,"
echo "then run: bash bootstrap/scripts/install-tools.sh && make preflight"
