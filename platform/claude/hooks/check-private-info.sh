#!/usr/bin/env bash
# PreToolUse hook — block/warn before git commit or git push if the change
# set contains private information (API keys, secrets, public IPs, emails,
# operator-specific identifiers).
#
# Triage rule:
#   - PUBLIC repo  + findings   → DENY (the commit/push is blocked).
#   - PRIVATE repo + findings   → WARN (operator sees a banner; proceeds).
#   - Unknown visibility (no remote, no gh, gh unauthenticated, etc.) →
#                                 treat as PUBLIC → DENY. Better to bother
#                                 the operator than to leak.
#
# Hook contract (Claude Code 2026):
#   - stdin:  JSON with tool_name, tool_input.command, hook_event_name.
#   - stdout: {"hookSpecificOutput": {"permissionDecision": "deny", ...}}
#             to block; {"continue": true, "systemMessage": "..."} to warn.
#   - exit 0 in both cases — the JSON drives the decision, not the code.
#
# Library mode: source with CHECK_PRIVATE_INFO_LIB=1 to expose
# scan_for_private_info() without running the hook (used by tests).
set -uo pipefail

scan_for_private_info() {
  # Scans a unified-diff payload on stdin. Prints findings (one per line,
  # prefixed with "- "). Empty output = clean.
  #
  # Additions from test files are skipped — fixtures legitimately embed
  # patterns that look like secrets. The path filter tracks the current
  # file via "+++ b/<path>" headers; when no headers are present (e.g.,
  # in unit tests that feed raw `+line` content), nothing is skipped.
  local content
  content="$(cat)"
  [ -n "${content}" ] || return 0

  local added
  added="$(printf '%s\n' "${content}" | awk '
    function is_test_path(p) {
      if (p ~ /^tests\//)                                       return 1
      if (p ~ /\/tests\//)                                      return 1
      if (p ~ /^test\//)                                        return 1
      if (p ~ /\/test\//)                                       return 1
      if (p ~ /__tests__\//)                                    return 1
      if (p ~ /\/fixtures\//)                                   return 1
      if (p ~ /\/testdata\//)                                   return 1
      if (p ~ /test_.+\.(sh|py|js|ts|tsx|go|rs)$/)              return 1
      if (p ~ /_test\.(sh|py|js|ts|tsx|go|rs)$/)                return 1
      if (p ~ /\.(test|spec)\.(js|jsx|ts|tsx|py)$/)             return 1
      return 0
    }
    /^\+\+\+ b\// {
      path = substr($0, 7)
      skip = is_test_path(path)
      next
    }
    /^\+\+\+ \/dev\/null/ { skip = 1; next }
    /^---/ { next }
    /^\+[^+]/ {
      if (!skip) print
    }
  ' || true)"
  [ -n "${added}" ] || return 0

  # 1. API keys / tokens (Anthropic, OpenAI, Stripe, AWS, GitHub, Slack).
  local match
  match="$(printf '%s\n' "${added}" | grep -oE '(sk-[a-zA-Z0-9_-]{20,}|sk_live_[a-zA-Z0-9]{20,}|sk_test_[a-zA-Z0-9]{20,}|AKIA[0-9A-Z]{16}|ghp_[a-zA-Z0-9]{20,}|gho_[a-zA-Z0-9]{20,}|xox[bp]-[a-zA-Z0-9-]{10,})' | head -5 || true)"
  [ -n "${match}" ] && printf -- '- API key / token: %s\n' "$(printf '%s' "${match}" | tr '\n' ' ')"

  # 2. Private key blocks.
  if printf '%s' "${added}" | grep -qE -- '-----BEGIN [A-Z ]*PRIVATE KEY-----'; then
    printf -- '- private key block (-----BEGIN ... PRIVATE KEY-----)\n'
  fi

  # 3. Credential-shaped assignments: (secret|password|token|api_key|auth)
  # followed by = or : and a 20+ char value. Excludes lines that look like
  # examples (placeholders, dollar-sign vars, *_EXAMPLE, .example files).
  match="$(printf '%s\n' "${added}" \
    | grep -iE '^\+.*(secret|password|passwd|token|api[_-]?key|auth)["[:space:]]*[:=][[:space:]]*["'"'"']?[A-Za-z0-9+/=_-]{20,}' \
    | grep -vE '\$\{|\$[A-Z_]+|\<example\>|EXAMPLE|placeholder|\.\.\.\>|<your-|<redacted>' \
    | head -3 || true)"
  if [ -n "${match}" ]; then
    while IFS= read -r line; do
      [ -z "${line}" ] && continue
      printf -- '- credential-shaped assignment: %s\n' "$(printf '%s' "${line}" | cut -c1-140)"
    done <<< "${match}"
  fi

  # 4. Email addresses (excluding placeholders).
  match="$(printf '%s\n' "${added}" \
    | grep -oE '[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}' \
    | grep -viE '@(example\.com|example\.org|your-domain|localhost|noreply\.)' \
    | sort -u | head -5 || true)"
  [ -n "${match}" ] && printf -- '- email(s): %s\n' "$(printf '%s' "${match}" | tr '\n' ' ')"

  # 5. Public-looking IPv4 (excluding RFC1918, loopback, doc ranges, etc.).
  local all_ips ip pub_ips=""
  all_ips="$(printf '%s' "${added}" | grep -oE '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' | sort -u || true)"
  while IFS= read -r ip; do
    [ -z "${ip}" ] && continue
    case "${ip}" in
      10.*|127.*|0.*|255.*|192.168.*|169.254.*) continue ;;
      172.16.*|172.17.*|172.18.*|172.19.*|172.2[0-9].*|172.3[01].*) continue ;;
      192.0.2.*|198.51.100.*|203.0.113.*) continue ;;
    esac
    pub_ips+="${ip} "
  done <<< "${all_ips}"
  [ -n "${pub_ips}" ] && printf -- '- public-looking IPv4: %s\n' "${pub_ips% }"

  # 6. Operator-local deny patterns (one regex per line; # for comments).
  local deny="${HOME}/.claude/private-info.deny"
  if [ -f "${deny}" ]; then
    local pattern
    while IFS= read -r pattern; do
      case "${pattern}" in ''|\#*) continue ;; esac
      if printf '%s' "${added}" | grep -qiE -- "${pattern}"; then
        printf -- '- operator deny pattern matched: %s\n' "${pattern}"
      fi
    done < "${deny}"
  fi
}

# Library mode: tests source this file and call scan_for_private_info directly.
[ "${CHECK_PRIVATE_INFO_LIB:-0}" = "1" ] && return 0 2>/dev/null

# --- Hook entry point below this line. -------------------------------------

input="$(cat)"

# Tool gating: this is a PreToolUse hook on Bash. Anything else, no-op.
tool="$(printf '%s' "${input}" | jq -r '.tool_name // ""' 2>/dev/null || echo '')"
cmd="$(printf '%s' "${input}" | jq -r '.tool_input.command // ""' 2>/dev/null || echo '')"
[ "${tool}" = "Bash" ] || exit 0

# Command gating: only act on git commit / git push.
case "${cmd}" in
  *"git commit"*|*"git push"*) ;;
  *) exit 0 ;;
esac

# Are we in a git repo at all? If not, the command will error out on its own.
git rev-parse --git-dir >/dev/null 2>&1 || exit 0

# Build the diff payload to scan.
diff_content=""
case "${cmd}" in
  *"git push"*)
    # Scan everything ahead of the upstream tracking branch. If there's no
    # upstream, fall back to commits not on any remote.
    if git rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1; then
      diff_content="$(git log '@{u}..HEAD' --pretty=format: -p 2>/dev/null || true)"
    else
      diff_content="$(git log --all --not --remotes --pretty=format: -p 2>/dev/null || true)"
    fi
    # Also include uncommitted-but-staged changes — `git commit && git push`
    # in one shell call would otherwise miss the staged piece on the push.
    diff_content+="$(printf '\n'; git diff --cached 2>/dev/null || true)"
    ;;
  *"git commit"*)
    diff_content="$(git diff --cached 2>/dev/null || true)"
    ;;
esac

[ -n "${diff_content}" ] || exit 0

findings="$(printf '%s' "${diff_content}" | scan_for_private_info)"
[ -n "${findings}" ] || exit 0

# Determine visibility of the destination repo.
visibility="UNKNOWN"
remote_url="$(git config --get remote.origin.url 2>/dev/null || true)"
if [ -z "${remote_url}" ]; then
  visibility="LOCAL"
elif command -v gh >/dev/null 2>&1; then
  v="$(gh repo view --json visibility -q .visibility 2>/dev/null || true)"
  case "${v}" in
    PUBLIC)             visibility="PUBLIC" ;;
    PRIVATE|INTERNAL)   visibility="PRIVATE" ;;
  esac
fi

lower_vis="$(printf '%s' "${visibility}" | tr '[:upper:]' '[:lower:]')"

case "${visibility}" in
  PUBLIC|UNKNOWN)
    reason="$(printf 'Private info detected before "%s" on a %s repo. Blocking.\n\nFindings:\n%s\nIf these are false positives, add patterns to %s/.claude/private-info.deny and try again.\n' \
      "${cmd}" "${lower_vis}" "${findings}" "${HOME}")"
    jq -nc --arg reason "${reason}" '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: $reason
      }
    }'
    ;;
  PRIVATE|LOCAL)
    msg="$(printf '⚠️ Private info detected before "%s" on a %s repo (proceeding):\n%s' \
      "${cmd}" "${lower_vis}" "${findings}")"
    jq -nc --arg msg "${msg}" '{
      continue: true,
      systemMessage: $msg
    }'
    ;;
esac
exit 0
