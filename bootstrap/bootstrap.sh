#!/usr/bin/env bash
# Platform bootstrap orchestrator.
#
# Privilege model: root-shell-via-sudo. The operator runs:
#     sudo -i
#     cd /opt/infra && ./bootstrap/bootstrap.sh
# No permanent passwordless sudo is configured. The password is entered once
# (by `sudo -i`); every numbered script then runs as root, unattended.
#
# Idempotent: safe to re-run on a fresh or already-provisioned VM.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

require_root
load_env

# Ask once which optional components to install. Answers persist to .env via
# set_env_var, so re-runs and disaster-recovery runs are non-interactive.
# Without a TTY (CI) undecided components default to install. The hardened
# base (00-04) and verify (99) always run and are never prompted for.
select_components() {
  local var label ans profile
  profile="${OBSERVABILITY_PROFILE:-lightweight}"
  for entry in \
    "INSTALL_GLANCES|Glances (host metrics)" \
    "INSTALL_DOZZLE|Dozzle (container logs)" \
    "INSTALL_NTOPNG|ntopng (network traffic, ~256 MB RAM)" \
    "INSTALL_CLAUDE|Claude Code + browser terminal" \
    "INSTALL_DASHBOARD|platform dashboard landing page"
  do
    var="${entry%%|*}"
    label="${entry#*|}"
    # Already decided in .env -> keep it (non-interactive on re-runs).
    if [ -n "${!var:-}" ]; then
      continue
    fi
    # The lightweight-only tools do not exist on the full profile.
    case "${var}" in
      INSTALL_GLANCES|INSTALL_DOZZLE|INSTALL_NTOPNG)
        if [ "${profile}" != "lightweight" ]; then continue; fi ;;
    esac
    ans=""
    if [ -t 0 ]; then
      printf '  Install %s? [Y/n]: ' "${label}" >&2
      read -r ans || true
    fi
    case "${ans}" in
      [Nn]*) ans=false ;;
      *)     ans=true ;;
    esac
    set_env_var "${var}" "${ans}"
    log INFO "component ${var}=${ans}"
  done
}
select_components
load_env   # re-load so the numbered steps inherit the component choices

STEPS=(
  00-prerequisites.sh
  01-user-and-ssh.sh
  02-firewall.sh
  03-kernel-hardening.sh
  04-docker.sh
  05-authelia.sh
  06-caddy.sh
  07-ttyd.sh
  08-observability.sh
  09-claude-code.sh
  10-dashboard.sh
  99-verify.sh
)

log INFO "bootstrap starting (${#STEPS[@]} steps)"
for step in "${STEPS[@]}"; do
  path="${SCRIPT_DIR}/${step}"
  [ -x "${path}" ] || chmod +x "${path}"
  log INFO "=== running ${step} ==="
  INFRA_CURRENT_SCRIPT="${step%.sh}" bash "${path}"
  log INFO "=== completed ${step} ==="
done
log INFO "bootstrap complete; platform layer operational"
