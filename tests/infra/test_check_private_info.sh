#!/usr/bin/env bash
# Unit tests for hooks/check-private-info.sh.
#
# Sources the hook in library mode (CHECK_PRIVATE_INFO_LIB=1) and exercises
# scan_for_private_info() against synthetic diff inputs. Pattern detection
# only — the full PreToolUse decision flow (visibility detection, JSON
# output shape) is exercised manually in dev; mocking gh is out of scope
# for these tests.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="${HERE}/../../platform/claude/hooks/check-private-info.sh"

pass=0; fail=0
ok() { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; }

[ -f "${HOOK}" ] || { echo "missing ${HOOK}"; exit 1; }

CHECK_PRIVATE_INFO_LIB=1
# shellcheck disable=SC1090
. "${HOOK}"
set +eu

scan() { printf '%s\n' "$1" | scan_for_private_info; }

contains() {
  # contains <label> <output> <needle>
  case "$2" in
    *"$3"*) ok "$1" ;;
    *)      no "$1 (output: ${2//$'\n'/ | })" ;;
  esac
}
clean() {
  # clean <label> <output>
  if [ -z "$2" ]; then ok "$1"; else no "$1 (unexpected output: $2)"; fi
}

echo "clean inputs:"
clean "empty diff produces no findings"     "$(scan '')"
clean "added line of plain text is clean"   "$(scan '+just a plain English line')"
clean "context-only diff (no + lines) is clean" "$(scan '-removed line
 context line')"
clean "placeholder email is ignored"        "$(scan '+email: ops@example.com')"
clean "rfc1918 ip is ignored"               "$(scan '+server at 192.168.1.10')"
clean "loopback ip is ignored"              "$(scan '+listening on 127.0.0.1')"

echo
echo "credentials:"
# Build secret-shaped strings from parts so the literal patterns never
# appear in this file's source. External secret scanners (e.g., GitHub
# push protection) match contiguous literals; this fixture-defeat trick
# keeps unit tests runnable without bypassing those protections.
ANT='sk-ant'
GHP='ghp'
XOXB='xoxb'
SK_LIVE='sk_live'

out="$(scan "+ANTHROPIC_API_KEY=${ANT}-NOT-A-REAL-KEY-NOT-A-REAL-KEY-XX")"
contains "anthropic key detected"      "${out}" "API key / token"
out="$(scan '+AWS_KEY=AKIAIOSFODNN7EXAMPLE')"
contains "aws access key detected"     "${out}" "AKIAIOSFODNN7EXAMPLE"
out="$(scan "+token = ${GHP}_NOT_A_REAL_GITHUB_PERSONAL_TOKEN_X")"
contains "github pat detected"         "${out}" "${GHP}_"
out="$(scan "+slack: ${XOXB}-NOT-REAL-NOT-REAL-NOT-A-REAL-SLACK-TOKEN")"
contains "slack bot token detected"    "${out}" "${XOXB}-"

echo
echo "private keys:"
out="$(scan '+-----BEGIN RSA PRIVATE KEY-----
+MIIE
+-----END RSA PRIVATE KEY-----')"
contains "rsa private key block"       "${out}" "private key block"

echo
echo "credential-shaped assignments:"
out="$(scan "+stripe_secret = \"${SK_LIVE}_NOT_A_REAL_STRIPE_KEY_NOT_REAL\"")"
contains "credential assignment fires" "${out}" "credential-shaped assignment"
out="$(scan '+password = "Aaaaaaaaaaaaaaaaaaaaaaaa"')"
contains "password assignment fires"   "${out}" "credential-shaped assignment"
clean "env-var reference is not a credential" "$(scan '+password = "${MY_PASS}"')"

echo
echo "emails:"
out="$(scan '+contact: ops@realcompany.io')"
contains "real email detected"         "${out}" "ops@realcompany.io"
clean "noreply.x is ignored"  "$(scan '+from: bot@noreply.example.com')"

echo
echo "public ips:"
out="$(scan '+ssh root@45.88.188.119')"
contains "public ip detected"          "${out}" "45.88.188.119"
out="$(scan '+frontends: 10.0.0.1 172.20.0.5 8.8.8.8')"
contains "public ip mixed with rfc1918" "${out}" "8.8.8.8"

echo
echo "test-file skipping:"
diff_text='diff --git a/tests/test_foo.sh b/tests/test_foo.sh
--- a/tests/test_foo.sh
+++ b/tests/test_foo.sh
@@ -0,0 +1 @@
++AWS_SECRET="AKIAIOSFODNN7EXAMPLE"
diff --git a/src/real.py b/src/real.py
--- a/src/real.py
+++ b/src/real.py
@@ -0,0 +1 @@
++plain real code line, no secrets'
out="$(printf '%s\n' "${diff_text}" | scan_for_private_info)"
clean "secrets in tests/ are skipped" "${out}"

diff_text="diff --git a/lib/foo.spec.ts b/lib/foo.spec.ts
+++ b/lib/foo.spec.ts
+const fakeKey = \"AKIAIOSFODNN7EXAMPLE\""
out="$(printf '%s\n' "${diff_text}" | scan_for_private_info)"
clean "secrets in .spec.ts are skipped" "${out}"

diff_text="diff --git a/src/prod.py b/src/prod.py
+++ b/src/prod.py
+token = \"AKIAIOSFODNN7EXAMPLE\""
out="$(printf '%s\n' "${diff_text}" | scan_for_private_info)"
contains "secrets in non-test files still caught" "${out}" "AKIAIOSFODNN7EXAMPLE"

echo
printf 'pass=%d fail=%d\n' "${pass}" "${fail}"
[ "${fail}" -eq 0 ]
