#!/usr/bin/env bash
# 04 - kernel hardening via sysctl drop-in. Idempotent (file is rewritten).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/lib/common.sh"
require_root

cat > /etc/sysctl.d/99-infra-hardening.conf <<'EOF'
# Managed by infra/bootstrap/04-kernel-hardening.sh
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.all.log_martians = 1
net.ipv6.conf.all.accept_redirects = 0
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
EOF

sysctl --system >/dev/null
log INFO "kernel hardening applied"
