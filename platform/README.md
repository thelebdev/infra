# Platform services

Definitions of the platform-level services: SSO gate, reverse proxy, web
terminal, observability stack, backup orchestrator.

## Structure

- `authelia/` — single-sign-on portal (Authelia).
  - `docker-compose.yml` — single container, SQLite local storage.
  - `configuration.yml.template` — rendered at bootstrap.
  - `users_database.yml.template` — single operator user (argon2id hash).
  - Secrets at `secrets/` and the rendered configs are gitignored.
- `caddy/` — reverse proxy with TLS, `forward_auth` to Authelia.
  - `Caddyfile.template` — rendered at bootstrap, subdomain-per-service.
  - `docker-compose.yml` — host-network Caddy container.
- `ttyd/` — systemd unit template serving Claude Code in a browser tab via
  `127.0.0.1:7681`, fronted by Caddy + Authelia.
- `observability/` — observability stack.
  - `docker-compose.lightweight.yml` — Glances + Dozzle + ntopng (default).
  - `docker-compose.full.yml` — Loki + Prometheus + Grafana (>= 2 GiB RAM).
  - `config/` — Loki, Promtail, Prometheus configs (full profile).
- `backup/` — restic configuration and orchestration (planned).
