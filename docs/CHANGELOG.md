# Changelog

Human-readable history of infrastructure changes for this fork.

## Format

Each entry: date, mode (Maintain / Manage / Create), one-line summary.

## Entries

- **2026-05-21** — Create — `bootstrap.sh` now prompts once for which optional
  components to install (Glances, Dozzle, ntopng, Claude, dashboard), at
  per-tool granularity. Answers persist to `.env` as `INSTALL_*` flags so
  re-runs and disaster-recovery runs are non-interactive. Each optional step,
  the Caddy routes, the dashboard tool list, and `99-verify.sh` honour the
  selection; the hardened base stays mandatory.
- **2026-05-21** — Maintain — Disabled ntopng's built-in login
  (`--disable-login=1`). Access to `ntopng.<PRIMARY_DOMAIN>` is now gated
  solely by Authelia, consistent with Dozzle and Glances. ntopng stays bound
  to `127.0.0.1`.
- **2026-05-21** — Create — Added a **platform dashboard**: a static landing
  page indexing every tool, served by Caddy at the apex domain and
  `dashboard.<PRIMARY_DOMAIN>`, gated by Authelia (new `10-dashboard.sh`
  step; apex added to Authelia's two-factor rule). The browser Claude
  session's **working directory is now configurable** — `07-ttyd.sh` prompts
  for `CLAUDE_WORKDIR` on an interactive first install, creates it, and
  persists it to `.env`. `05-authelia.sh` now renders `users_database.yml`
  **once** so users added later survive re-runs; added
  `platform/authelia/add-user.sh` to add an Authelia user (password + TOTP).
- **2026-05-20** — Maintain — Replaced Caddy HTTP basic-auth with **Authelia
  SSO + TOTP** gating every subdomain via Caddy `forward_auth`. Added **ttyd**
  serving Claude Code in a browser tab at `claude.<PRIMARY_DOMAIN>` (gated
  by Authelia). Bootstrap renumbered to fit the new gate-first ordering:
  `00 prereq → 01 user/ssh → 02 firewall → 03 kernel → 04 docker → 05 authelia → 06 caddy → 07 ttyd → 08 observability → 09 claude-code → 99 verify`.
  `qrencode` added to prerequisites; TOTP enrollment QR printed once at
  bootstrap and stashed at `/opt/infra/.authelia-enrollment`.
