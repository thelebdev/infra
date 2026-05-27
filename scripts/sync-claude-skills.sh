#!/usr/bin/env bash
# Mirror ~/.claude/ → platform/claude/ (Mac source → repo snapshot).
#
# Direction matters: the source of truth is the operator's ~/.claude/, where
# Claude actively edits skills mid-session. This script reflects those edits
# back into the repo so the next `git pull` rolls them out to every server.
#
# The reverse direction (repo → server users' ~/.claude/) is handled by
# bootstrap/12-claude-skills.sh on each server. Do NOT run this script on a
# server — it would clobber the server-side mirror with the server admin's
# (potentially empty) ~/.claude/ contents.
#
# Behavior:
#   - skills/:    rsync --delete, plus EXCLUDED_SKILLS
#   - commands/:  rsync --delete
#   - CLAUDE.md:  copied up to (but not including) the <!-- PUBLIC-CUTOFF -->
#                 marker — anything below the marker stays operator-private.
#                 The marker is required; missing it aborts the sync.
#   - settings.json: copied verbatim.
#   - Scanner runs at the end. Findings block the sync.
#
# Idempotent. Run it before committing any change to platform/claude/.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${HERE}/.." && pwd)"
SRC="${HOME}/.claude"
DST="${REPO_ROOT}/platform/claude"

# Skills never published as part of the cross-project bundle. The first entry
# is a sensible default for this repo (overall-infra-architect is repo-scoped
# under .claude/skills/, not a generic skill). Operators can add personal
# skills to scripts/sync-claude-skills.local-exclude (gitignored).
EXCLUDED_SKILLS=( overall-infra-architect )
LOCAL_EXCLUDE_FILE="${HERE}/sync-claude-skills.local-exclude"
if [ -f "${LOCAL_EXCLUDE_FILE}" ]; then
  while IFS= read -r line; do
    case "${line}" in ''|\#*) continue ;; esac
    EXCLUDED_SKILLS+=( "${line}" )
  done < "${LOCAL_EXCLUDE_FILE}"
fi

CUTOFF_MARKER="<!-- PUBLIC-CUTOFF -->"

die() { printf 'sync-claude-skills: %s\n' "$*" >&2; exit 1; }

# Safety: refuse to run on a server. A simple heuristic — the repo path
# pattern on the Mac dev box vs. /opt/infra on a server.
case "${REPO_ROOT}" in
  /opt/infra*|/srv/infra*)
    die "this script must run on the dev box, not on a server (REPO_ROOT=${REPO_ROOT})" ;;
esac

[ -d "${SRC}/skills" ]        || die "no ${SRC}/skills"
[ -d "${SRC}/commands" ]      || die "no ${SRC}/commands"
[ -f "${SRC}/CLAUDE.md" ]     || die "no ${SRC}/CLAUDE.md"
[ -f "${SRC}/settings.json" ] || die "no ${SRC}/settings.json"
# hooks/ is optional — only operators using PreToolUse hooks will have one.

command -v rsync >/dev/null 2>&1 || die "rsync not installed"

mkdir -p "${DST}/skills" "${DST}/commands"
[ -d "${SRC}/hooks" ] && mkdir -p "${DST}/hooks"

echo "sync-claude-skills: mirroring ${SRC} -> ${DST#${REPO_ROOT}/}"
echo "  excluded skills: ${EXCLUDED_SKILLS[*]}"

# Build rsync excludes.
exclude_args=()
for s in "${EXCLUDED_SKILLS[@]}"; do
  exclude_args+=( --exclude="${s}" )
done

# Mirror skills (--delete so removals propagate; --exclude keeps personal
# skills out of the public copy).
rsync -a --delete "${exclude_args[@]}" "${SRC}/skills/" "${DST}/skills/"

# Defense in depth: if an excluded skill is somehow already in DST (manual
# add, prior sync without the exclude), purge it now. rsync --exclude
# protects the source side; this protects the destination.
for s in "${EXCLUDED_SKILLS[@]}"; do
  if [ -e "${DST}/skills/${s}" ]; then
    rm -rf "${DST}/skills/${s}"
    echo "  purged stale excluded skill from mirror: ${s}"
  fi
done

# Mirror commands.
rsync -a --delete "${SRC}/commands/" "${DST}/commands/"

# Mirror hooks (if any). The hook scripts are publishable; the operator's
# personal exclusion list at ~/.claude/private-info.deny is NOT in ~/.claude/hooks/
# and stays local.
if [ -d "${SRC}/hooks" ]; then
  rsync -a --delete "${SRC}/hooks/" "${DST}/hooks/"
fi

# CLAUDE.md: copy up to (but not including) the cutoff marker. Refuse if the
# marker is missing — it likely means the operator forgot to demarcate.
if ! grep -qF "${CUTOFF_MARKER}" "${SRC}/CLAUDE.md"; then
  die "no '${CUTOFF_MARKER}' marker in ${SRC}/CLAUDE.md
    Add a line containing exactly: ${CUTOFF_MARKER}
    Everything above the marker syncs to the public CLAUDE.md.example;
    everything below stays operator-private."
fi

awk -v m="${CUTOFF_MARKER}" '
  index($0, m) { exit }
  { print }
' "${SRC}/CLAUDE.md" > "${DST}/CLAUDE.md.example"

# settings.json: verbatim.
cp "${SRC}/settings.json" "${DST}/settings.json.example"

# Scanner gate. The scanner's operator-local deny list catches any personal
# identifier that slipped through the source.
"${REPO_ROOT}/security/scan-claude-skills.sh"

echo
echo "sync-claude-skills: done. Diff vs. HEAD:"
cd "${REPO_ROOT}"
if git diff --quiet -- platform/claude/ && git diff --cached --quiet -- platform/claude/; then
  echo "  (no changes — platform/claude/ already matches ~/.claude/)"
else
  git status -s -- platform/claude/
  echo
  echo "Review the diff (git diff platform/claude/), stage what you want, commit."
fi
