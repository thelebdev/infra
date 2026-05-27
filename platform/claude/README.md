# platform/claude

Claude Code skills, commands, and starter templates that ship with the
repo and get deployed to every operator's `~/.claude/` on bootstrap.

## What's here

```
platform/claude/
├── skills/                  # one dir per skill, each contains SKILL.md
├── commands/                # slash-commands (one .md per command)
├── CLAUDE.md.example        # sanitized global-preferences template
└── settings.json.example    # status line, plugins, defaults
```

The deployer that distributes these is `bootstrap/12-claude-skills.sh`.
It runs as part of `bootstrap.sh` (gated by `INSTALL_CLAUDE_SKILLS`,
defaults `true`) and is also invoked from `platform/authelia/add-user.sh`
when the new Authelia user happens to also have a Linux account.

## Deploy model

For every target user (`SERVER_ADMIN_USER` plus any Authelia user that
also exists as a Linux user with a home directory):

| What lands in `~/.claude/`            | How              | Behavior on re-run |
|---------------------------------------|------------------|--------------------|
| `skills/<name>` (per skill)           | **symlink** into the repo | `git pull` → updated instantly. Stale symlinks pointing elsewhere are replaced. |
| `commands/<name>.md` (per command)    | **symlink** into the repo | Same as above. |
| `CLAUDE.md`                           | **copy** from `CLAUDE.md.example` | Created only when absent. Never overwritten. |
| `settings.json`                       | **copy** from `settings.json.example` | Created only when absent. Never overwritten. |

The deployer is **idempotent** (safe to re-run on every `git pull`) and
**non-destructive** (a real file or user-modified directory in
`~/.claude/skills/<name>` is preserved with a WARN log — never clobbered).

## Source of truth

The operator's `~/.claude/` on the dev box is the source of truth. Claude
edits skills there mid-session (via `new-skill`, self-update flows, manual
edits). `scripts/sync-claude-skills.sh` mirrors `~/.claude/` → this
directory; `git pull` then rolls the new content to every server, where
`bootstrap/12-claude-skills.sh` symlinks it into each user's `~/.claude/`.

```
~/.claude/ (dev box, source)
    ↓ scripts/sync-claude-skills.sh
platform/claude/ (this dir, repo mirror)
    ↓ bootstrap/12-claude-skills.sh
~/.claude/ (server users, symlinked from the repo)
```

Sync rules (enforced by `scripts/sync-claude-skills.sh`):

- Skills mirrored 1:1 except for `EXCLUDED_SKILLS` (default:
  `overall-infra-architect`). Operators can add personal skills to
  `scripts/sync-claude-skills.local-exclude` (gitignored).
- Commands mirrored 1:1.
- `CLAUDE.md` copied up to (but not including) `<!-- PUBLIC-CUTOFF -->`.
  Everything below stays private. Put `## My defaults`, `## My context`,
  vault refs, and brand specifics below the marker.
- `settings.json` copied verbatim.
- The secret-and-PII scanner runs at the end. Findings abort the sync.

## How operators customize a skill on a server

Two options:

**1. Edit on your dev box, sync, PR** — preferred. The change goes through
review and ships to every operator on the next deploy.

**2. Replace the symlink with a real directory** — local-only override.

```bash
cd ~/.claude/skills
rm code-review                       # remove the symlink
cp -R /opt/infra/platform/claude/skills/code-review .
$EDITOR code-review/SKILL.md
```

On the next deploy, the WARN log will note that your real directory is
being preserved. To go back to the shared version: `rm -rf code-review`
and re-run `sudo /opt/infra/bootstrap/12-claude-skills.sh`.

## How to add a new skill

1. Create it under `~/.claude/skills/<new-skill>/SKILL.md` on the dev box
   (the `/new-skill` command does this).
2. Use it for a while. Iterate.
3. When it's ready to share: `./scripts/sync-claude-skills.sh` mirrors
   `~/.claude/` into the repo and runs the scanner. Findings abort.
4. Review the diff, commit, PR. CI re-runs the scanner.
5. After merge, `git pull` on each server picks it up; the next run of
   `12-claude-skills.sh` symlinks it for every user. (Or it just appears
   on next bootstrap — symlinks are created lazily on every run.)

## How to update `CLAUDE.md` for everyone vs. just yourself

Edit `~/.claude/CLAUDE.md` on the dev box.

- Changes **above** the `<!-- PUBLIC-CUTOFF -->` marker reach the public
  template (`platform/claude/CLAUDE.md.example`) on next sync, and from
  there reach *new* operators only. Existing `~/.claude/CLAUDE.md` files
  on servers are never overwritten.
- Changes **below** the marker stay operator-private and never leave the
  dev box.

For personal vendor or brand specifics (Bitwarden, Hetzner, your brand
URL, etc.), keep the prose generic above the cutoff and reference a named
variable; put the concrete value in `## My defaults` below the cutoff.
The `design-tokens` skill demonstrates this pattern with `DEFAULT_BRAND_URL`.

## What's not here (and why)

- **`overall-infra-architect`** — lives at `.claude/skills/` in the repo
  root, not under `platform/claude/skills/`. It governs work on *this*
  repo specifically (loaded automatically by Claude Code when you open
  the repo), not as a generic cross-project skill. Don't move it.
- **The operator's personal `CLAUDE.md`** — never committed. The
  publishable version is `CLAUDE.md.example`, with the personal "My
  context" section stubbed out for each operator to fill in locally.
- **Anything matched by `security/scan-claude-skills.sh`** — emails,
  API keys, public IPs, private keys, plus an operator's local deny
  patterns from `security/scan-claude-skills.deny` (gitignored).

