#!/usr/bin/env python3
"""claude-break-out — TOTP-gated launch of Claude Code with break-out.

Invoked as ``sudo claude-break-out`` from inside a tmux-managed bwrap'd
shell (in practice, via the ``/usr/local/bin/claude`` shim that the sandbox
puts on PATH — so the operator just types ``claude``). Sudo verifies the
operator's password every invocation (see /etc/sudoers.d/break:
``Defaults!claude-break-out timestamp_timeout=0``). This tool then prompts
for the operator's 6-digit Authelia TOTP code, validates it against the
secret in Authelia's encrypted SQLite store, and on success replaces the
calling pane's process with an unconfined login bash that immediately
``exec``s Claude Code.

The replacement shell is spawned by tmux itself — which runs outside the
sandbox — so the pane *becomes* unconfined. Same window, same scrollback,
no new tab. Bash is used as a one-shot launcher so ``.profile`` runs first
(to put ``~/.local/bin`` on PATH where ``claude`` lives), then ``exec``s
claude with no shell layered underneath. Quitting claude exits the pane.

Two factors required to launch:
  1. The operator's host sudo password (the ``sudo`` wrapper validates).
  2. The current 6-digit Authelia TOTP code (validated here against the
     encrypted secret in Authelia's SQLite database).

No network calls; the TOTP is verified locally against the same secret
Authelia itself reads on login.

Requires (installed by bootstrap/07-ttyd.sh):
  - python3-cryptography  (AES-256-GCM decryption of Authelia's secret blob)
  - /opt/infra/platform/authelia/db.sqlite3  (root-readable)
  - /opt/infra/platform/authelia/secrets/storage  (root-readable; the
     storage encryption key)

NOTE: the TOTP validation logic below duplicates platform/ttyd/break.py.
A follow-up PR should extract them into a shared module
(platform/ttyd/totp_gate.py) — kept duplicated here for now to keep this
change focused.
"""
from __future__ import annotations

import base64
import getpass
import hashlib
import hmac
import os
import sqlite3
import struct
import subprocess
import sys
import time
from pathlib import Path

try:
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
except ImportError:  # pragma: no cover
    AESGCM = None  # type: ignore[assignment]

AUTHELIA_DIR = Path("/opt/infra/platform/authelia")
DB_PATH = AUTHELIA_DIR / "db.sqlite3"
KEY_PATH = AUTHELIA_DIR / "secrets" / "storage"
ENV_PATH = Path("/opt/infra/.env")
TOTP_WINDOW_SECONDS = 30
TOTP_SKEW_WINDOWS = (-1, 0, 1)


def die(msg: str) -> None:
    print(f"claude-break-out: {msg}", file=sys.stderr)
    sys.exit(1)


def authelia_decrypt(blob: bytes) -> bytes:
    if AESGCM is None:
        die("python3-cryptography is not installed "
            "(run: sudo apt install python3-cryptography)")
    try:
        key_str = KEY_PATH.read_text().strip()
    except OSError as exc:
        die(f"cannot read storage key at {KEY_PATH}: {exc}")
    key = hashlib.sha256(key_str.encode()).digest()
    if len(blob) < 12 + 16:
        die("encrypted secret is too short to be valid AES-GCM ciphertext")
    nonce, ct = blob[:12], blob[12:]
    try:
        return AESGCM(key).decrypt(nonce, ct, None)
    except Exception as exc:  # noqa: BLE001
        die(f"could not decrypt TOTP secret: {exc} "
            "(storage key may have changed since enrolment)")


def get_totp_secret(username: str) -> str:
    if not DB_PATH.exists():
        die(f"Authelia DB not found at {DB_PATH}")
    conn = sqlite3.connect(str(DB_PATH))
    try:
        row = conn.execute(
            "SELECT secret FROM totp_configurations WHERE username = ?",
            (username,)).fetchone()
    except sqlite3.OperationalError as exc:
        die(f"Authelia DB query failed ({exc}); is the schema as expected?")
    finally:
        conn.close()
    if not row or row[0] is None:
        die(f"no TOTP enrolled for Authelia user '{username}'")
    return authelia_decrypt(row[0]).decode().strip()


def compute_totp(secret_b32: str, t: int,
                 step: int = TOTP_WINDOW_SECONDS, digits: int = 6) -> str:
    counter = max(t // step, 0)
    counter_bytes = struct.pack(">Q", counter)
    secret = base64.b32decode(secret_b32.upper())
    h = hmac.new(secret, counter_bytes, hashlib.sha1).digest()
    offset = h[-1] & 0x0f
    code = ((h[offset] & 0x7f) << 24 |
            h[offset + 1] << 16 |
            h[offset + 2] << 8 |
            h[offset + 3]) % (10 ** digits)
    return str(code).zfill(digits)


def validate_totp(secret_b32: str, supplied: str) -> bool:
    if not supplied.isdigit() or len(supplied) != 6:
        return False
    now = int(time.time())
    expected = {compute_totp(secret_b32, now + w * TOTP_WINDOW_SECONDS)
                for w in TOTP_SKEW_WINDOWS}
    return any(hmac.compare_digest(supplied, exp) for exp in expected)


def respawn_pane_with_claude() -> None:
    """Replace the calling pane's process with an unconfined login bash
    that immediately execs Claude Code.

    ``tmux respawn-pane`` runs in tmux's process context (outside bwrap),
    so the new bash and the claude it execs are both unconfined. Using
    ``bash -l -c 'exec claude'`` is the simplest way to get PATH from
    ``.profile`` (where ``~/.local/bin`` is added by 09-claude-code.sh)
    without resolving the binary path here — and ``exec`` means quitting
    claude exits the pane rather than dropping to a bash prompt."""
    tmux = os.environ.get("TMUX") or die("not running inside a tmux pane")
    pane = os.environ.get("TMUX_PANE") or die("TMUX_PANE not set")
    sock = tmux.split(",", 1)[0]
    subprocess.run(
        ["tmux", "-S", sock, "respawn-pane", "-t", pane, "-k",
         "--", "/bin/bash", "-l", "-c", "exec claude"],
        check=True)


def resolve_username() -> str:
    if len(sys.argv) >= 2 and sys.argv[1]:
        return sys.argv[1]
    if os.environ.get("TTYD_USER"):
        return os.environ["TTYD_USER"]
    if ENV_PATH.exists():
        for line in ENV_PATH.read_text().splitlines():
            if line.startswith("AUTHELIA_USER="):
                value = line.split("=", 1)[1].strip()
                if value:
                    return value
    return "admin"


def main() -> None:
    if os.geteuid() != 0:
        die("must be invoked via `sudo claude-break-out` "
            "(the `claude` shim inside the sandbox does this for you)")
    if not os.environ.get("TMUX"):
        die("must be run inside a tmux session "
            "(this is the 'launch Claude after TOTP' tool)")

    username = resolve_username()
    secret = get_totp_secret(username)
    code = getpass.getpass(f"Authelia TOTP for {username}: ").strip()
    if not validate_totp(secret, code):
        die("invalid TOTP code")

    print(f"✓ verified — launching Claude for {username} outside the sandbox")
    respawn_pane_with_claude()


if __name__ == "__main__":
    main()
