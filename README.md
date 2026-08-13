# Anarchy Pizza Docker Reference 🍕

This repository is a curated collection of Docker Compose configurations for various self-hosted applications. It's designed as a "Reference Architecture" to help friends and fellow enthusiasts set up a robust, portable, and easily maintainable home server stack — including a full single sign-on layer, not just individual apps.

**As of 2026-08-13, the live stack runs on k3s, not Docker Compose.** Every app in the table below was migrated to Kubernetes (Helm charts, Argo CD GitOps sync) — see `k8s/README.md` for the k8s-side layout and `migration_plan.md` for the full migration story, every real bug hit along the way, and why. The Docker Compose configs below remain fully intact and documented (every app's `docker-compose.yml`, its own `.env.example`, real data on disk) as an instant rollback path — `docker compose up -d` in any `apps/<app>/` brings that app's old Compose version back — but Compose itself is not the live path anymore, and the sections below describe how the stack *used to* run day-to-day, not how it runs now. Everything from **Architecture Overview** onward (SSO patterns, storage tiers, security posture) still applies conceptually; only the actual runtime (Compose → k3s) changed.

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

**For the current live deployment (k3s):** see `k8s/README.md` for the directory layout and `migration_plan.md` for the full setup story. Broad strokes: k3s + Helm + Argo CD, one Argo CD `Application` per app under `k8s/apps/`, auto-synced from this repo. There's no separate "run this to deploy" script — pushing to `main` is the deploy mechanism.

The steps below describe the **Docker Compose path** — still fully functional as a rollback, and the reference for what each app's k3s config mirrors, but not how the live stack actually runs day-to-day anymore.

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

See `archived/migration_plan.md` for the full history of how this pattern evolved, every gotcha hit along the way, and the NPM→Traefik cutover itself (including a live incident worth reading before touching a shared router's TLS config). A new `migration_plan.md` now tracks the in-progress Kubernetes/Helm/Argo CD migration.

## 🏗️ Architecture Overview

### Request path
```
Internet → Traefik (public TLS via Let's Encrypt, ports 80/443)
              → CrowdSec bouncer (entrypoint-level middleware, every router)
                  → Authelia (forward-auth or OIDC, as needed)
                      → the app
```
Traefik owns the public edge directly and terminates TLS itself (Let's Encrypt, HTTP-01) — in the current k3s deployment, via a `Certificate`/`ClusterIssuer` through cert-manager rather than Traefik's own built-in ACME resolver (which the Compose version used); running both against the same domains would race each other. Nginx Proxy Manager, which used to sit in front of Traefik doing this job, has been fully retired — its compose file and data are kept on disk as an instant rollback path (`docker compose up -d` in `apps/npm`), but it is not running. Every app is reachable only through Traefik otherwise — removing an app's leftover direct host port is a standard, expected step when migrating it onto this pattern (see the Security Notes below; this bit us in practice, more than once).

**Edge protection**: [CrowdSec](https://www.crowdsec.net/) (`apps/crowdsec/`, Compose version — see `k8s/apps/` for the running k3s version) reads Traefik's and Vaultwarden's logs and feeds ban decisions to a Traefik plugin applied per-router (in k3s, via a shared `Middleware` referenced from every app's `IngressRoute` — functionally the same "every router gets it automatically" outcome as the Compose entrypoint-level config). The k3s version reads pod logs natively through the Kubernetes API (its own DaemonSet-based acquisition) rather than a Docker-socket mount. It runs ahead of Authelia's own login-form brute-force protection and is the only thing guarding apps that don't sit behind Authelia yet (Vaultwarden). Enrolled in CrowdSec's community blocklist (CAPI). See `apps/crowdsec/SETUP.md` for the original Compose (one-time, order-dependent) bootstrap.

### Single sign-on: three patterns, by what the app supports
Authelia is backed by LLDAP (LDAP identity store, never exposed publicly — Tailscale-only in the old Compose setup; in k3s, cluster-internal only via `kubectl port-forward`, arguably even stricter, though real tailnet access to the admin UI isn't wired up yet, see `migration_plan.md`) and is itself also configured as an OIDC provider. Which pattern an app gets depends on what it natively supports:

| Pattern | How it works | Apps using it |
|---|---|---|
| **Forward-auth gate** | Traefik calls Authelia before every request; the app itself has no auth (or its own login is disabled) | Dozzle, Uptime Kuma, SearXNG, Friendica (here for a different reason — see below) |
| **Header-auth SSO** | Authelia forwards a trusted header (`Remote-User`/`Remote-Email`); the app trusts it directly — real single login | FreshRSS, Calibre-web, Open WebUI |
| **Native OIDC** | The app talks to Authelia's OIDC endpoints itself; no forward-auth middleware needed | Vikunja, Homarr, Matrix (alongside native accounts - see `apps/matrix/SETUP.md`) |

Access is role-based via two LDAP groups — `admins` (full access) and `users` (deny-listed from a few apps) — not per-app allow-lists.

Apps not yet on this pattern: **Vaultwarden** (has its own native OIDC support, not yet wired up — it is on Traefik/TLS now, just not behind Authelia), and **LLDAP** (internal-only by design, see above).

**Friendica** (staged in `wip/`, not yet deployed) is a special case: it's on the forward-auth gate not as a login mechanism but as a federation kill switch. It's a federated (ActivityPub) app with no in-app way to disable federation, so the Authelia gate — sitting in front of every path, including `/inbox` and `/.well-known/webfinger` — is what will keep it unreachable by other servers once it's deployed. See `wip/friendica/SETUP.md` for the full reasoning and how to go public/federated later.

### Storage tiers
- `gold/`: Fast storage (SSD/NVMe) for databases and high-IO apps.
- `silver/`: Standard storage for general app configs — also where every app's non-git secrets live (`${STORAGE_ROOT}/silver/<app>/secrets/`).
- `bronze/`: Bulk storage for less sensitive or large data.

### Monitoring
Dozzle gives real-time logs for every container in a web UI — behind SSO at `https://dozzle.${DOMAIN}`, not on a public port. (An earlier version of this stack had it on a bare host port with zero auth; don't do that.)

## 📦 Current Apps

All apps below are **live in k3s** (see `k8s/apps/<app>/`); the `apps/` directory referenced throughout this table is the Docker Compose reference/rollback config each k3s app was migrated from, not the running instance.

**Active** (`apps/`):

| App | Public URL | Auth |
|---|---|---|
| Authelia | `auth.${DOMAIN}` | — (it's the SSO provider) |
| Dozzle | `dozzle.${DOMAIN}` | Forward-auth gate |
| Uptime Kuma | `uptime.${DOMAIN}` | Forward-auth gate |
| SearXNG | `search.${DOMAIN}` | Forward-auth gate |
| FreshRSS | `news.${DOMAIN}` | Header-auth SSO |
| Calibre-web | `library.${DOMAIN}` | Header-auth SSO |
| Open WebUI | `llm.${DOMAIN}` | Header-auth SSO |
| Vikunja | `vikunja.${DOMAIN}` | Native OIDC |
| Homarr | `homarr.${DOMAIN}` | Native OIDC |
| Vaultwarden | `vault.${DOMAIN}` | None yet (candidate) |
| Matrix (Synapse) | `matrix.${DOMAIN}` | Native OIDC (Authelia) + native Synapse accounts (registration closed, admin-created) side by side |
| Element Web | `chat.${DOMAIN}` | — (client only; auth happens against Synapse) |
| LLDAP | internal-only (Tailscale) | — (identity backend) |
| Traefik | — | — (the proxy layer itself; owns public TLS directly) |
| CrowdSec | — (internal LAPI only, `crowdsec:8080`) | — (edge protection layer for every app above; see Architecture Overview) |

**Work in progress** (`wip/`) — staged, not deployed; `update-all-apps.sh` only walks `apps/`, so these are inert until moved:
- **Friendica** (`wip/friendica/`) — planned at `friendica.${DOMAIN}`, forward-auth gate (federation intentionally off until it's moved to `apps/` — see `wip/friendica/SETUP.md`).

**Archived** (`archived/`) — retired or replaced, compose files kept for reference, data intentionally left on disk rather than deleted:
- **Nginx Proxy Manager (NPM)** → fully retired once Traefik took over public TLS/routing directly. Kept as an instant rollback path (`docker compose up -d` in `apps/npm`), not deleted.
- **Portainer** — decommissioned by choice, not part of the active stack.
- **CommaFeed** → replaced by FreshRSS (no viable SSO path existed for CommaFeed).
- **MinIO** → its open-source Console SSO was removed upstream by the vendor (and the project's GitHub repo was later archived entirely); no direct replacement currently running.
- **RustFS** → attempted MinIO replacement; abandoned after real, unresolved OIDC and data-durability bugs surfaced in the beta software.
- A handful of others (`bandcampsync`, `nextcloud`, `qbittorrentvpn`) predate the SSO rollout — see git history for context on each.
- **n8n**, tried twice, retired both times — not by bug, by choice (workflow-builder UX wasn't a fit for this stack's admin). `archived/n8n` is the original pre-SSO attempt (direct host port, queue mode with a separate worker + Redis, no Traefik/Authelia). `archived/n8n-sso` is the later, fully-working redo (forward-auth gate via Authelia admins-only, webhook/form-trigger paths deliberately bypassing the gate since external callers can't do a login redirect, single container - queue mode was overkill for a single-node homelab). See git history around 2026-08-13 for the full Traefik-priority and Authelia-session debugging that went into `n8n-sso`.
- **`archived/matrix`** — an earlier, incomplete Matrix attempt (dead config, never actually deployed — see its own history for the DB-password lesson learned). Superseded by the working `apps/matrix` + `apps/element-web`, deliberately kept off the SSO pattern above and fully non-federated by design. See `apps/matrix/SETUP.md`.

For the full blow-by-blow — every gotcha, every bug, every decision and why — see **`archived/migration_plan.md`** (Traefik/Authelia SSO rollout) and **`migration_plan.md`** (in-progress Kubernetes/Helm/Argo CD migration). Working logs, not polished docs, but the ground truth for anything not obvious from the compose files themselves.

## 🔒 Security Notes

- **Check for leftover host ports when migrating an app onto the Traefik/Authelia pattern.** An app that pre-dates this pattern usually still has a `ports:` entry from its old direct-NPM setup — leaving it in place means the app is reachable directly, bypassing Authelia entirely, regardless of how well the SSO side is configured. This happened for real (Dozzle, Uptime Kuma, Calibre-web) and is now an explicit step in `migration_plan.md`'s per-app checklist.
- **Header-auth apps must never be reachable except through Traefik.** Trusting a `Remote-User`-style header means anyone who can reach the app directly can forge it.
- **LLDAP's admin UI is intentionally never exposed publicly** — it manages every account in the system, including Authelia's own. It's bound to this host's Tailscale interface only.
- Real secrets (LDAP bind passwords, OIDC client secrets, encryption keys) live host-only under `${STORAGE_ROOT}/silver/*/secrets/` and are **not** committed to git — only placeholder `.env.example` files are tracked.
- A pre-commit hook (`.githooks/pre-commit`, wired up by `bootstrap.sh` via `core.hooksPath`) runs [gitleaks](https://github.com/gitleaks/gitleaks) against staged changes and blocks the commit if it finds anything secret-shaped. Requires `gitleaks` on `PATH` (`sudo apt install gitleaks`, or see the linked install docs) — the hook refuses to commit unscanned if it's missing. Bypass with `git commit --no-verify` only for confirmed false positives.
- **CrowdSec is edge protection, not an auth replacement.** It bans IPs after they trip a scenario (repeated failed logins, scanning, known-bad community IPs) — it doesn't gate access the way Authelia does. Apps not yet behind Authelia (Vaultwarden) still need their own login to actually be strong; CrowdSec just makes brute-forcing it much more expensive.

## ⚠️ Disclaimer

This is a **reference** repository reflecting a specific personal setup, including a real SSO/identity layer with real security implications — not a hardened, general-purpose product. Review every `docker-compose.yml` and the Security Notes above before deploying anything from here, especially the auth-related pieces.

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
