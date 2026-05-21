#!/usr/bin/env bash
# 07 - ttyd: web terminal that serves Claude Code in a browser tab.
# Reachable at claude.<PRIMARY_DOMAIN> through Caddy (gated by Authelia).
# Binds to 127.0.0.1:7681 only.
#
# Runs as the admin user via systemd so the PTY inherits the admin's $HOME,
# PATH, and access to claude / claude-session. No container — keeps the
# stack of moving parts small.
#
# No-op if PRIMARY_DOMAIN is unset (no public surface to attach to).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/lib/common.sh"
require_root

if [ -z "${PRIMARY_DOMAIN:-}" ]; then
  log WARN "PRIMARY_DOMAIN unset; skipping ttyd (would have no public route anyway)."
  exit 0
fi

# Optional component: the browser terminal can be deselected at bootstrap.
INSTALL_CLAUDE="${INSTALL_CLAUDE:-true}"
if [ "${INSTALL_CLAUDE}" != "true" ]; then
  log INFO "INSTALL_CLAUDE=${INSTALL_CLAUDE}; skipping the ttyd web terminal"
  systemctl disable --now ttyd-claude.service 2>/dev/null || true
  exit 0
fi

# Resolve admin user (same logic as 01-user-and-ssh, 09-claude-code).
ADMIN="${SERVER_ADMIN_USER:-${SUDO_USER:-}}"
if [ -z "${ADMIN}" ] || [ "${ADMIN}" = "root" ]; then
  ADMIN="$(stat -c '%U' "${INFRA_ROOT}" 2>/dev/null || true)"
fi
[ -n "${ADMIN}" ] && [ "${ADMIN}" != "root" ] || die "cannot resolve admin user"
ADMIN_HOME="$(getent passwd "${ADMIN}" | cut -d: -f6)"
[ -n "${ADMIN_HOME}" ] || die "cannot resolve home for ${ADMIN}"

# Install ttyd from Ubuntu universe.
apt_ensure ttyd

# Ubuntu's ttyd package ships /usr/lib/systemd/system/ttyd.service which is
# auto-enabled and runs `ttyd -i lo -p 7681 -O login` as root — i.e. a
# password-login prompt exposed on port 7681. We replace that with our own
# unit running as the admin user, gated by Authelia. Stop+mask the default.
if systemctl list-unit-files ttyd.service >/dev/null 2>&1; then
  systemctl stop    ttyd.service 2>/dev/null || true
  systemctl disable ttyd.service 2>/dev/null || true
  systemctl mask    ttyd.service 2>/dev/null || true
  log INFO "default ttyd.service stopped + masked (replaced by ttyd-claude.service)"
fi

# Sanity: claude-session helper should exist (09-claude-code installs it).
# But on first bootstrap 07 runs BEFORE 09 — so it may not be there yet.
# That's fine; the service will retry on Restart=on-failure once 09 lands it.
if [ ! -x "${ADMIN_HOME}/.local/bin/claude-session" ]; then
  log INFO "claude-session not yet present at ${ADMIN_HOME}/.local/bin/ — 09-claude-code installs it"
fi

# Resolve CLAUDE_WORKDIR: the directory the browser Claude session opens in.
# Prompt once on an interactive first install when it is blank, then persist
# the answer to .env so re-runs and disaster-recovery runs (where .env is
# already populated) stay non-interactive. No TTY (e.g. CI) -> use the default.
if [ -z "${CLAUDE_WORKDIR:-}" ]; then
  if [ -t 0 ]; then
    printf '\n  Working directory the browser Claude session (claude.%s) opens in.\n' \
      "${PRIMARY_DOMAIN}" >&2
    printf '  Press Enter for the default (%s): ' "${ADMIN_HOME}" >&2
    read -r CLAUDE_WORKDIR || true
  fi
  CLAUDE_WORKDIR="${CLAUDE_WORKDIR:-${ADMIN_HOME}}"
fi
# Normalise the path. `read` does not perform tilde expansion, so expand a
# leading ~ ourselves; resolve any still-relative answer against the admin
# home so a bare name typed at the prompt does not hard-fail.
# SC2088: the "~/" pattern below is a literal case-pattern match, not an
# attempt at tilde expansion; quoting it is correct.
# shellcheck disable=SC2088
case "${CLAUDE_WORKDIR}" in
  "~")    CLAUDE_WORKDIR="${ADMIN_HOME}" ;;
  "~/"*)  CLAUDE_WORKDIR="${ADMIN_HOME}/${CLAUDE_WORKDIR:2}" ;;
  /*)     : ;;
  *)      CLAUDE_WORKDIR="${ADMIN_HOME}/${CLAUDE_WORKDIR}" ;;
esac
case "${CLAUDE_WORKDIR}" in
  /*) : ;;
  *)  die "could not resolve CLAUDE_WORKDIR to an absolute path: '${CLAUDE_WORKDIR}'" ;;
esac
set_env_var CLAUDE_WORKDIR "${CLAUDE_WORKDIR}"
if [ -d "${CLAUDE_WORKDIR}" ]; then
  log INFO "claude working directory ${CLAUDE_WORKDIR} already exists"
else
  install -d -o "${ADMIN}" -g "${ADMIN}" "${CLAUDE_WORKDIR}"
  log INFO "created claude working directory ${CLAUDE_WORKDIR} (owner ${ADMIN})"
fi

# Render the systemd unit.
TEMPLATE="${INFRA_ROOT}/platform/ttyd/ttyd-claude.service.template"
UNIT=/etc/systemd/system/ttyd-claude.service
[ -f "${TEMPLATE}" ] || die "missing ${TEMPLATE}"

python3 - "${TEMPLATE}" "${UNIT}" "${ADMIN}" "${ADMIN_HOME}" "${CLAUDE_WORKDIR}" <<'PYEOF'
import sys
src, dst, user, home, workdir = sys.argv[1:6]
content = open(src).read()
content = content.replace("__ADMIN_USER__", user)
content = content.replace("__ADMIN_HOME__", home)
content = content.replace("__CLAUDE_WORKDIR__", workdir)
open(dst, "w").write(content)
PYEOF
chmod 644 "${UNIT}"
log INFO "rendered ${UNIT} (user=${ADMIN}, workdir=${CLAUDE_WORKDIR})"

systemctl daemon-reload
systemctl enable ttyd-claude.service >/dev/null 2>&1 || true
systemctl restart ttyd-claude.service
# Give it a moment; restart=on-failure handles the case where claude-session
# isn't installed yet (first bootstrap, before step 09).
sleep 1
systemctl is-active --quiet ttyd-claude.service || \
  log WARN "ttyd-claude not yet active (likely waiting for 09-claude-code to install claude-session); will retry on restart"
log INFO "ttyd-claude unit installed; reachable via claude.${PRIMARY_DOMAIN} after 09-claude-code lands"
