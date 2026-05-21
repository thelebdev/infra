#!/usr/bin/env bash
# 10 - platform dashboard: a static landing page indexing every tool the
# platform exposes. Rendered from a template and served by Caddy (file_server)
# at the apex domain and <SUBDOMAIN_DASHBOARD>.<PRIMARY_DOMAIN>, gated by
# Authelia.
#
# The page lists only the tools actually installed (per the INSTALL_* flags),
# each at whatever subdomain label was chosen (the SUBDOMAIN_* flags).
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
SUBDOMAIN_AUTH="${SUBDOMAIN_AUTH:-auth}"
SUBDOMAIN_DASHBOARD="${SUBDOMAIN_DASHBOARD:-dashboard}"
SUBDOMAIN_CLAUDE="${SUBDOMAIN_CLAUDE:-claude}"
SUBDOMAIN_DOZZLE="${SUBDOMAIN_DOZZLE:-dozzle}"
SUBDOMAIN_GLANCES="${SUBDOMAIN_GLANCES:-glances}"
SUBDOMAIN_NTOPNG="${SUBDOMAIN_NTOPNG:-ntopng}"
SUBDOMAIN_GRAFANA="${SUBDOMAIN_GRAFANA:-grafana}"

# Emit one tool card. __PRIMARY_DOMAIN__ is substituted by the render below.
mkcard() {
  printf '<a class="card" href="https://%s.__PRIMARY_DOMAIN__"><span class="card-name">%s</span><span class="card-desc">%s</span><span class="card-host">%s.__PRIMARY_DOMAIN__</span></a>' \
    "$1" "$2" "$3" "$1"
}

CLAUDE_CARD=""
[ "${INSTALL_CLAUDE}" = "true" ] && CLAUDE_CARD="$(mkcard "${SUBDOMAIN_CLAUDE}" 'Claude Code' 'Agent terminal in the browser')"
# Glances/Dozzle/ntopng exist only on the lightweight profile.
DOZZLE_CARD=""
GLANCES_CARD=""
NTOPNG_CARD=""
if [ "${PROFILE}" = "lightweight" ]; then
  [ "${INSTALL_DOZZLE}"  = "true" ] && DOZZLE_CARD="$(mkcard "${SUBDOMAIN_DOZZLE}" 'Dozzle' 'Live container logs')"
  [ "${INSTALL_GLANCES}" = "true" ] && GLANCES_CARD="$(mkcard "${SUBDOMAIN_GLANCES}" 'Glances' 'Host metrics: CPU, memory, disk')"
  [ "${INSTALL_NTOPNG}"  = "true" ] && NTOPNG_CARD="$(mkcard "${SUBDOMAIN_NTOPNG}" 'ntopng' 'Network traffic and flows')"
fi
GRAFANA_CARD=""
[ "${PROFILE}" = "full" ] && GRAFANA_CARD="$(mkcard "${SUBDOMAIN_GRAFANA}" 'Grafana' 'Metrics and log dashboards')"

python3 - "${TEMPLATE}" "${OUT}" "${PRIMARY_DOMAIN}" "${SUBDOMAIN_AUTH}" \
  "${CLAUDE_CARD}" "${DOZZLE_CARD}" "${GLANCES_CARD}" "${NTOPNG_CARD}" "${GRAFANA_CARD}" <<'PYEOF'
import sys
src, dst, domain, sub_auth, claude, dozzle, glances, ntopng, grafana = sys.argv[1:10]
content = open(src).read()
for token, card in (("__CLAUDE_CARD__", claude), ("__DOZZLE_CARD__", dozzle),
                     ("__GLANCES_CARD__", glances), ("__NTOPNG_CARD__", ntopng),
                     ("__GRAFANA_CARD__", grafana)):
    content = content.replace(token, card)
content = content.replace("__SUBDOMAIN_AUTH__", sub_auth)
content = content.replace("__PRIMARY_DOMAIN__", domain)
open(dst, "w").write(content)
PYEOF
chmod 644 "${OUT}"
log INFO "rendered platform dashboard -> ${OUT} (profile=${PROFILE})"
log INFO "dashboard served by Caddy at https://${PRIMARY_DOMAIN} and https://${SUBDOMAIN_DASHBOARD}.${PRIMARY_DOMAIN}"
