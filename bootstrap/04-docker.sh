#!/usr/bin/env bash
# 05 - Docker Engine + Compose v2. Idempotent: verifies if already present,
# installs otherwise via the official convenience script.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/lib/common.sh"
require_root

if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  log INFO "docker present: $(docker --version), $(docker compose version --short)"
else
  log INFO "installing docker via official convenience script"
  curl -fsSL https://get.docker.com | sh
fi

ensure_service docker

# Sane daemon defaults: capped json logs so a chatty container can't fill disk.
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "live-restore": true
}
EOF
systemctl reload docker 2>/dev/null || systemctl restart docker
log INFO "docker ready (log rotation + live-restore configured)"
