#!/usr/bin/env bash
# 07 - Claude Code on the host (remote-management agent).
# Installed for the admin user. Idempotent. Auth is a deliberate manual step:
# either `claude login` over the SSH session, or ANTHROPIC_API_KEY from .env
# exported in the admin shell.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/lib/common.sh"
require_root

# Optional component: Claude Code on the host can be deselected at bootstrap.
INSTALL_CLAUDE="${INSTALL_CLAUDE:-true}"
if [ "${INSTALL_CLAUDE}" != "true" ]; then
  log INFO "INSTALL_CLAUDE=${INSTALL_CLAUDE}; skipping Claude Code install"
  exit 0
fi

ADMIN="${SERVER_ADMIN_USER:-${SUDO_USER:-}}"
if [ -z "${ADMIN}" ] || [ "${ADMIN}" = "root" ]; then
  ADMIN="$(stat -c '%U' "${INFRA_ROOT}" 2>/dev/null || true)"
fi
[ -n "${ADMIN}" ] && [ "${ADMIN}" != "root" ] || \
  die "cannot resolve admin user; set SERVER_ADMIN_USER=<user> in ${INFRA_ENV_FILE}"
ADMIN_HOME="$(getent passwd "${ADMIN}" | cut -d: -f6)"

if sudo -u "${ADMIN}" bash -lc 'command -v claude' >/dev/null 2>&1; then
  log INFO "claude code already installed for ${ADMIN}"
else
  log INFO "installing claude code for ${ADMIN}"
  sudo -u "${ADMIN}" bash -lc 'curl -fsSL https://claude.ai/install.sh | bash'
fi

# The installer drops the binary in ~/.local/bin, which is not reliably on
# PATH for non-interactive/login shells. Put it there idempotently for both
# login (.profile) and interactive (.bashrc) shells, owned by the admin user.
PATHLINE='export PATH="$HOME/.local/bin:$PATH"'
for rc in "${ADMIN_HOME}/.profile" "${ADMIN_HOME}/.bashrc"; do
  ensure_line "${PATHLINE}" "${rc}"
  chown "${ADMIN}:${ADMIN}" "${rc}" 2>/dev/null || true
done

# Install the shared-session helper: one always-on Claude Code instance in a
# named tmux session, attachable from any device (laptop, phone), surviving
# disconnects. Same live instance for everyone who attaches.
HELPER="${ADMIN_HOME}/.local/bin/claude-session"
install -d -o "${ADMIN}" -g "${ADMIN}" "${ADMIN_HOME}/.local/bin"
cat > "${HELPER}" <<'EOF'
#!/usr/bin/env bash
# Attach to the shared, always-on Claude Code session, or create it.
# Run from any device; same live instance. Detach (keep it running):
# Ctrl-b then d.
#
# Working directory precedence: explicit first argument, else CLAUDE_WORKDIR
# from /opt/infra/.env, else $HOME. The directory only applies when the
# session is first created; an existing session keeps its directory until it
# is killed (re-running bootstrap restarts it).
set -euo pipefail
workdir="${1:-}"
if [ -z "${workdir}" ]; then
  workdir="$(grep -m1 '^CLAUDE_WORKDIR=' /opt/infra/.env 2>/dev/null | cut -d= -f2- || true)"
fi
[ -n "${workdir}" ] && [ -d "${workdir}" ] || workdir="${HOME}"
exec tmux new-session -A -s claude -c "${workdir}" claude
EOF
chmod +x "${HELPER}"
chown "${ADMIN}:${ADMIN}" "${HELPER}"
log INFO "installed claude-session helper for ${ADMIN}"

# Make the API key available to the admin shell only if provided (never logged).
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  ENVLINE='export ANTHROPIC_API_KEY="$(grep -m1 "^ANTHROPIC_API_KEY=" '"${INFRA_ENV_FILE}"' | cut -d= -f2-)"'
  ensure_line "${ENVLINE}" "${ADMIN_HOME}/.bashrc"
  log INFO "ANTHROPIC_API_KEY wired into ${ADMIN} shell from .env"
else
  log WARN "ANTHROPIC_API_KEY not set; run 'claude login' over SSH to authenticate"
fi

VER="$(sudo -u "${ADMIN}" bash -lc 'claude --version' 2>/dev/null || echo unknown)"
log INFO "claude code ready for ${ADMIN} (version: ${VER})"
