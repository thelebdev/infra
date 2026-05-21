#!/usr/bin/env bash
# 10 - platform dashboard: a static landing page indexing every tool the
# platform exposes. Rendered from a template and served by Caddy (file_server)
# at the apex domain and dashboard.<PRIMARY_DOMAIN>, gated by Authelia.
#
# The page lists only the tools actually installed (per the INSTALL_* flags).
# No-op if PRIMARY_DOMAIN is unset, or if INSTALL_DASHBOARD is not "true".
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/lib/common.sh"
require_root

DASH_DIR="${INFRA_ROOT}/platform/dashboard"
TEMPLATE="${DASH_DIR}/index.html.template"
OUT="${DASH_DIR}/index.html"

if [ -z "${PRIMARY_DOMAIN:-}" ]; then
  log WARN "PRIMARY_DOMAIN unset; skipping dashboard (no Caddy to serve it)."
  exit 0
fi

INSTALL_DASHBOARD="${INSTALL_DASHBOARD:-true}"
if [ "${INSTALL_DASHBOARD}" != "true" ]; then
  log INFO "INSTALL_DASHBOARD=${INSTALL_DASHBOARD}; skipping the dashboard"
  rm -f "${OUT}"
  exit 0
fi

[ -f "${TEMPLATE}" ] || die "missing ${TEMPLATE}"

PROFILE="${OBSERVABILITY_PROFILE:-lightweight}"
INSTALL_CLAUDE="${INSTALL_CLAUDE:-true}"
INSTALL_DOZZLE="${INSTALL_DOZZLE:-true}"
INSTALL_GLANCES="${INSTALL_GLANCES:-true}"
INSTALL_NTOPNG="${INSTALL_NTOPNG:-true}"

# Emit one tool card. __PRIMARY_DOMAIN__ is substituted by the render below.
mkcard() {
  printf '<a class="card" href="https://%s.__PRIMARY_DOMAIN__"><span class="card-name">%s</span><span class="card-desc">%s</span><span class="card-host">%s.__PRIMARY_DOMAIN__</span></a>' \
    "$1" "$2" "$3" "$1"
}

CLAUDE_CARD=""
[ "${INSTALL_CLAUDE}" = "true" ] && CLAUDE_CARD="$(mkcard claude 'Claude Code' 'Agent terminal in the browser')"
# Glances/Dozzle/ntopng exist only on the lightweight profile.
DOZZLE_CARD=""
GLANCES_CARD=""
NTOPNG_CARD=""
if [ "${PROFILE}" = "lightweight" ]; then
  [ "${INSTALL_DOZZLE}"  = "true" ] && DOZZLE_CARD="$(mkcard dozzle 'Dozzle' 'Live container logs')"
  [ "${INSTALL_GLANCES}" = "true" ] && GLANCES_CARD="$(mkcard glances 'Glances' 'Host metrics: CPU, memory, disk')"
  [ "${INSTALL_NTOPNG}"  = "true" ] && NTOPNG_CARD="$(mkcard ntopng 'ntopng' 'Network traffic and flows')"
fi
GRAFANA_CARD=""
[ "${PROFILE}" = "full" ] && GRAFANA_CARD="$(mkcard grafana 'Grafana' 'Metrics and log dashboards')"

python3 - "${TEMPLATE}" "${OUT}" "${PRIMARY_DOMAIN}" \
  "${CLAUDE_CARD}" "${DOZZLE_CARD}" "${GLANCES_CARD}" "${NTOPNG_CARD}" "${GRAFANA_CARD}" <<'PYEOF'
import sys
src, dst, domain, claude, dozzle, glances, ntopng, grafana = sys.argv[1:9]
content = open(src).read()
for token, card in (("__CLAUDE_CARD__", claude), ("__DOZZLE_CARD__", dozzle),
                     ("__GLANCES_CARD__", glances), ("__NTOPNG_CARD__", ntopng),
                     ("__GRAFANA_CARD__", grafana)):
    content = content.replace(token, card)
content = content.replace("__PRIMARY_DOMAIN__", domain)
open(dst, "w").write(content)
PYEOF
chmod 644 "${OUT}"
log INFO "rendered platform dashboard -> ${OUT} (profile=${PROFILE})"
log INFO "dashboard served by Caddy at https://${PRIMARY_DOMAIN} and https://dashboard.${PRIMARY_DOMAIN}"
