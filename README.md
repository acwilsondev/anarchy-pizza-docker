# Anarchy Pizza Docker Reference 🍕

This repository is a curated collection of Docker Compose configurations for various self-hosted applications. It's designed as a "Reference Architecture" to help friends and fellow enthusiasts set up a robust, portable, and easily maintainable home server stack — including a full single sign-on layer, not just individual apps.

## ✨ Key Features

- **Standardized Structure**: Each app lives in its own directory with its own `docker-compose.yml`.
- **Portable Storage**: All host paths are externalized via variables (`STORAGE_ROOT`, `MEDIA_ROOT`).
- **Zero-Downtime Updates**: A custom script updates containers only when new images or config changes are detected.
- **Direct Reverse Proxy**: Traefik owns the public edge directly — Docker-label routing plus automatic Let's Encrypt TLS, no separate proxy-manager UI in the loop.
- **Single Sign-On**: [Authelia](https://www.authelia.com/) gates every app that supports it, backed by [LLDAP](https://github.com/lldap/lldap) as the LDAP identity source — one login, one set of credentials, real group-based roles (`admins` / `users`).
- **Centralized Logging**: Includes **Dozzle** for a unified web-based view of all container logs (behind SSO, not on a public port).
- **Hardened Configs**: Resource limits, healthchecks, and no unnecessary direct host ports on anything that's routed through the proxy chain.

## 🛠️ Prerequisites

- **Docker Engine + Docker Compose v2**: Ensure you have the modern `docker compose` plugin installed.
- **Linux Environment**: Designed for Ubuntu/Debian, but adaptable to any system running Docker.
- **A real domain with DNS you control**: needed for Let's Encrypt certs on any public-facing app.
- **Basic Terminal Knowledge**: You'll need to be comfortable editing `.env` files and running scripts.
- **(Optional) [Tailscale](https://tailscale.com/)**: this reference keeps LLDAP's admin UI off the public internet entirely, reachable only over a tailnet.

## 🚀 Getting Started

### 1. Clone and Initialize
```bash
git clone https://github.com/your-username/anarchy-pizza-docker.git
cd anarchy-pizza-docker
```

### 2. Configure Your Environment
Copy the example environment file and edit it to match your host system's paths and domain:
```bash
cp .env.example .env
nano .env
```
*   Set `STORAGE_ROOT` to where you want app data (configs, DBs) to live.
*   Set `MEDIA_ROOT` to your media library path.
*   Set `DOMAIN` to your real base domain (e.g. `example.com`) — every Traefik-routed app hangs a subdomain off this (`dozzle.example.com`, `auth.example.com`, etc).

Some apps also need their own `.env` — copy each `apps/<app>/.env.example` to `apps/<app>/.env` and fill it in before starting that app.

### 3. Bootstrap the Network
Run the bootstrap script to create the shared `anarchy-pizza` network:
```bash
bash bootstrap.sh
```

### 4. Deploy Applications
You can start apps individually or all at once.

**To start a specific app** (both env files, root + the app's own, matter):
```bash
cd apps/dozzle
docker compose --env-file ../../.env --env-file .env up -d
```

**To update and start everything:**
```bash
bash update-all-apps.sh
```

### 5. Point DNS at your server
Every subdomain used by a Traefik-labeled app (`dozzle.${DOMAIN}`, `auth.${DOMAIN}`, etc) needs an A/AAAA record pointing at your server's public IP. Traefik handles TLS itself now (Let's Encrypt, HTTP-01) — no manual proxy-host setup needed per app, unlike earlier versions of this stack that chained through Nginx Proxy Manager. A new app just needs `traefik.enable=true` labels and correct DNS; the certificate is issued automatically on first request.

See `migration_plan.md` for the full history of how this pattern evolved, every gotcha hit along the way, and the NPM→Traefik cutover itself (including a live incident worth reading before touching a shared router's TLS config).

## 🏗️ Architecture Overview

### Request path
```
Internet → Traefik (public TLS via Let's Encrypt, ports 80/443)
              → Authelia (forward-auth or OIDC, as needed)
                  → the app
```
Traefik owns the public edge directly and terminates TLS itself (Let's Encrypt, HTTP-01). Nginx Proxy Manager, which used to sit in front of Traefik doing this job, has been fully retired — its compose file and data are kept on disk as an instant rollback path (`docker compose up -d` in `apps/npm`), but it is not running. Every app is reachable only over the internal `anarchy-pizza` Docker network otherwise — removing an app's leftover direct host port is a standard, expected step when migrating it onto this pattern (see the Security Notes below; this bit us in practice, more than once).

### Single sign-on: three patterns, by what the app supports
Authelia is backed by LLDAP (LDAP identity store, admin UI Tailscale-only, never exposed publicly) and is itself also configured as an OIDC provider. Which pattern an app gets depends on what it natively supports:

| Pattern | How it works | Apps using it |
|---|---|---|
| **Forward-auth gate** | Traefik calls Authelia before every request; the app itself has no auth (or its own login is disabled) | Dozzle, Uptime Kuma |
| **Header-auth SSO** | Authelia forwards a trusted header (`Remote-User`/`Remote-Email`); the app trusts it directly — real single login | FreshRSS, Calibre-web, Open WebUI |
| **Native OIDC** | The app talks to Authelia's OIDC endpoints itself; no forward-auth middleware needed | Vikunja, Homarr |

Access is role-based via two LDAP groups — `admins` (full access) and `users` (deny-listed from a few apps) — not per-app allow-lists.

Apps not yet on this pattern: **Vaultwarden** (has its own native OIDC support, not yet wired up — it is on Traefik/TLS now, just not behind Authelia), and **LLDAP** (internal-only by design, see above).

### Storage tiers
- `gold/`: Fast storage (SSD/NVMe) for databases and high-IO apps.
- `silver/`: Standard storage for general app configs — also where every app's non-git secrets live (`${STORAGE_ROOT}/silver/<app>/secrets/`).
- `bronze/`: Bulk storage for less sensitive or large data.

### Monitoring
Dozzle gives real-time logs for every container in a web UI — behind SSO at `https://dozzle.${DOMAIN}`, not on a public port. (An earlier version of this stack had it on a bare host port with zero auth; don't do that.)

## 📦 Current Apps

**Active** (`apps/`):

| App | Public URL | Auth |
|---|---|---|
| Authelia | `auth.${DOMAIN}` | — (it's the SSO provider) |
| Dozzle | `dozzle.${DOMAIN}` | Forward-auth gate |
| Uptime Kuma | `uptime.${DOMAIN}` | Forward-auth gate |
| FreshRSS | `news.${DOMAIN}` | Header-auth SSO |
| Calibre-web | `library.${DOMAIN}` | Header-auth SSO |
| Open WebUI | `llm.${DOMAIN}` | Header-auth SSO |
| Vikunja | `vikunja.${DOMAIN}` | Native OIDC |
| Homarr | `homarr.${DOMAIN}` | Native OIDC |
| Vaultwarden | `vault.${DOMAIN}` | None yet (candidate) |
| LLDAP | internal-only (Tailscale) | — (identity backend) |
| Traefik | — | — (the proxy layer itself; owns public TLS directly) |

**Archived** (`archived/`) — retired or replaced, compose files kept for reference, data intentionally left on disk rather than deleted:
- **Nginx Proxy Manager (NPM)** → fully retired once Traefik took over public TLS/routing directly. Kept as an instant rollback path (`docker compose up -d` in `apps/npm`), not deleted.
- **Portainer** — decommissioned by choice, not part of the active stack.
- **CommaFeed** → replaced by FreshRSS (no viable SSO path existed for CommaFeed).
- **MinIO** → its open-source Console SSO was removed upstream by the vendor (and the project's GitHub repo was later archived entirely); no direct replacement currently running.
- **RustFS** → attempted MinIO replacement; abandoned after real, unresolved OIDC and data-durability bugs surfaced in the beta software.
- A handful of others (`bandcampsync`, `matrix`, `n8n`, `nextcloud`, `qbittorrentvpn`) predate the SSO rollout — see git history for context on each.

For the full blow-by-blow — every gotcha, every bug, every decision and why — see **`migration_plan.md`**. It's a working log, not polished docs, but it's the ground truth for anything not obvious from the compose files themselves.

## 🔒 Security Notes

- **Check for leftover host ports when migrating an app onto the Traefik/Authelia pattern.** An app that pre-dates this pattern usually still has a `ports:` entry from its old direct-NPM setup — leaving it in place means the app is reachable directly, bypassing Authelia entirely, regardless of how well the SSO side is configured. This happened for real (Dozzle, Uptime Kuma, Calibre-web) and is now an explicit step in `migration_plan.md`'s per-app checklist.
- **Header-auth apps must never be reachable except through Traefik.** Trusting a `Remote-User`-style header means anyone who can reach the app directly can forge it.
- **LLDAP's admin UI is intentionally never exposed publicly** — it manages every account in the system, including Authelia's own. It's bound to this host's Tailscale interface only.
- Real secrets (LDAP bind passwords, OIDC client secrets, encryption keys) live host-only under `${STORAGE_ROOT}/silver/*/secrets/` and are **not** committed to git — only placeholder `.env.example` files are tracked.
- A pre-commit hook (`.githooks/pre-commit`, wired up by `bootstrap.sh` via `core.hooksPath`) runs [gitleaks](https://github.com/gitleaks/gitleaks) against staged changes and blocks the commit if it finds anything secret-shaped. Requires `gitleaks` on `PATH` (`sudo apt install gitleaks`, or see the linked install docs) — the hook refuses to commit unscanned if it's missing. Bypass with `git commit --no-verify` only for confirmed false positives.

## ⚠️ Disclaimer

This is a **reference** repository reflecting a specific personal setup, including a real SSO/identity layer with real security implications — not a hardened, general-purpose product. Review every `docker-compose.yml` and the Security Notes above before deploying anything from here, especially the auth-related pieces.

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
