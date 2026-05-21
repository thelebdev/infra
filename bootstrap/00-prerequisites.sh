#!/usr/bin/env bash
# 00 - prerequisites: base packages, locale, timezone, log dir.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/lib/common.sh"
require_root

mkdir -p "${INFRA_LOG_DIR}"

apt_ensure ca-certificates curl gnupg jq ufw fail2ban unattended-upgrades \
           apt-transport-https software-properties-common tmux \
           python3 openssl rsync qrencode

# Timezone: UTC on servers (logs/correlation). Operator-facing tooling localises.
timedatectl set-timezone Etc/UTC || true
log INFO "timezone set to Etc/UTC"

# Unattended security upgrades on.
ensure_line 'APT::Periodic::Update-Package-Lists "1";' /etc/apt/apt.conf.d/20auto-upgrades
ensure_line 'APT::Periodic::Unattended-Upgrade "1";'   /etc/apt/apt.conf.d/20auto-upgrades
systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true

log INFO "prerequisites complete"
