# Home Lab Kubernetes Reference

This repository is a curated GitOps reference for a self-hosted home server stack running on k3s — including a full single sign-on layer, not just individual apps. It's meant to help friends and fellow enthusiasts set up a robust, portable, and easily maintainable home server without hand-running commands against a live host.

**The stack runs on k3s (Helm charts, Argo CD GitOps sync)** — see `k8s/README.md` for the directory layout and `migration_plan.md` for the full migration story, every real bug hit along the way, and why. This repo previously also carried a parallel Docker Compose reference (every app's `docker-compose.yml`, its own `.env.example`) as a rollback path from the k3s cutover; once the cutover was proven stable, that Compose scaffolding was removed from the tree (2026-08-20 repo cleanup) — it's still recoverable from git history if ever needed, but is no longer maintained or kept in sync with the live config.

## ✨ Key Features

- **GitOps**: Argo CD watches `k8s/apps/` and syncs the cluster to match — desired state lives in git, drift is visible, no hand-run `kubectl apply` for day-to-day changes.
- **Standardized Structure**: Each app lives in its own directory under `k8s/apps/`, either a Helm chart + values file or plain manifests, with its own Argo CD `Application`.
- **Direct Reverse Proxy**: Traefik owns the public edge directly — Ingress-based routing plus automatic Let's Encrypt TLS via cert-manager, no separate proxy-manager UI in the loop.
- **Single Sign-On**: [Authelia](https://www.authelia.com/) gates every app that supports it, backed by [LLDAP](https://github.com/lldap/lldap) as the LDAP identity source — one login, one set of credentials, real group-based roles (`admins` / `users`).
- **Centralized Logging**: Includes **Dozzle** for a unified web-based view of all container logs (behind SSO, not on a public port).
- **Hardened Configs**: Resource limits, readiness/liveness probes, and no unnecessary direct host ports on anything that's routed through the proxy chain.

## 🛠️ Prerequisites

- **A k3s (or compatible single-node Kubernetes) host**, Helm, and Argo CD installed — see `migration_plan.md` for the exact toolchain and bootstrap order this reference followed.
- **A real domain with DNS you control**: needed for Let's Encrypt certs on any public-facing app.
- **Basic Kubernetes/Helm knowledge**: you'll need to be comfortable reading `values.yaml` files and Argo CD `Application` manifests.
- **(Optional) [Tailscale](https://tailscale.com/)**: this reference keeps LLDAP's admin UI and the Argo CD UI off the public internet entirely, reachable only over a tailnet (via the Tailscale Kubernetes Operator).

## 🚀 Getting Started

There's no separate "run this to deploy" script — pushing to `main` is the deploy mechanism, once Argo CD is bootstrapped.

### 1. Clone

```bash
git clone https://github.com/your-username/homelab-docker.git
cd homelab-docker
```

### 2. Stand up k3s, Helm, and Argo CD

Not scripted here — a single-node k3s install plus Helm and Argo CD, following `migration_plan.md`'s toolchain notes. `k3s`'s bundled Traefik/ServiceLB should stay disabled if you're using this repo's own Traefik deployment (`k8s/apps/traefik/`) to avoid a port 80/443 conflict.

### 3. Bootstrap Argo CD's root app

```bash
kubectl apply -f k8s/argocd/root-app.yaml
```

This is the one manual step — an app-of-apps root `Application` that watches `k8s/apps/` on `main` and auto-syncs (with prune + self-heal) everything under it from then on.

### 4. Point DNS at your server

Every subdomain used by a Traefik-routed app (`dozzle.${DOMAIN}`, `auth.${DOMAIN}`, etc) needs an A/AAAA record pointing at your server's public IP. Traefik + cert-manager handle TLS automatically (Let's Encrypt, HTTP-01) once a `Certificate`/`ClusterIssuer` and DNS are both in place — see `k8s/apps/ingress/certificate.yaml`. A new app just needs the right `IngressRoute` and correct DNS; the certificate covers it via a shared multi-SAN cert and `TLSStore`.

See `migration_plan.md` for the full history of how this stack got here — every gotcha hit along the way, both the original NPM→Traefik cutover on Compose and the later Compose→k3s migration.

## 🏗️ Architecture Overview

### Request path
```
Internet → Traefik (public TLS via Let's Encrypt/cert-manager, ports 80/443)
              → CrowdSec bouncer (shared Middleware, referenced from every IngressRoute)
                  → Authelia (forward-auth or OIDC, as needed)
                      → the app
```
Traefik owns the public edge directly and terminates TLS itself, via a `Certificate`/`ClusterIssuer` through cert-manager rather than Traefik's own built-in ACME resolver (running both against the same domains would race each other). Every app is reachable only through Traefik — an app with a leftover direct `NodePort`/`hostPort` bypasses Authelia entirely (see the Security Notes below; this bit the old Compose stack in practice, more than once, and is an explicit thing to check on any new app).

**Edge protection**: [CrowdSec](https://www.crowdsec.net/) (`k8s/apps/crowdsec/`) reads pod logs natively through the Kubernetes API (its own DaemonSet-based acquisition) and feeds ban decisions to a shared Traefik `Middleware` referenced from every app's `IngressRoute` — every router gets it automatically. It runs ahead of Authelia's own login-form brute-force protection and is the only thing guarding apps that don't sit behind Authelia yet (Vaultwarden). Enrolled in CrowdSec's community blocklist (CAPI).

### Single sign-on: three patterns, by what the app supports
Authelia is backed by LLDAP (LDAP identity store, cluster-internal only, reachable for administration via `kubectl port-forward` or the Tailscale Kubernetes Operator — never exposed on the public Traefik path) and is itself also configured as an OIDC provider. Which pattern an app gets depends on what it natively supports:

| Pattern | How it works | Apps using it |
|---|---|---|
| **Forward-auth gate** | Traefik calls Authelia before every request; the app itself has no auth (or its own login is disabled) | Dozzle, Uptime Kuma, SearXNG |
| **Header-auth SSO** | Authelia forwards a trusted header (`Remote-User`/`Remote-Email`); the app trusts it directly — real single login | FreshRSS, Calibre-web, Open WebUI |
| **Native OIDC** | The app talks to Authelia's OIDC endpoints itself; no forward-auth middleware needed | Vikunja, Homarr, Matrix (alongside native accounts — see `k8s/apps/matrix-synapse/values.yaml`) |

Access is role-based via two LDAP groups — `admins` (full access) and `users` (deny-listed from a few apps) — not per-app allow-lists.

Apps not yet on this pattern: **Vaultwarden** (has its own native OIDC support, not yet wired up — it is on Traefik/TLS now, just not behind Authelia), and **LLDAP** (internal-only by design, see above).

### Storage tiers
- `local-path-provisioner` PVCs for small/medium app state (databases, configs).
- `hostPath` straight at the physical bulk-storage disk for large data that needs to stay off the OS/root volume (Calibre-web's book library, Open WebUI's Ollama models).

### Monitoring
Dozzle gives real-time logs for every container in a web UI — behind SSO at `https://dozzle.${DOMAIN}`, not on a public port.

## 📦 Current Apps

All apps below are live in k3s (`k8s/apps/<app>/`), each its own Argo CD child `Application` under the app-of-apps root.

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
| vikunja-tagger | — (internal only, no ingress) | — (source: [acwilsondev/vikunja-tagger](https://github.com/acwilsondev/vikunja-tagger); webhook worker, auto-labels new Vikunja tasks via Ollama — see `k8s/apps/vikunja-tagger/SETUP.md`) |
| Homarr | `homarr.${DOMAIN}` | Native OIDC |
| Vaultwarden | `vault.${DOMAIN}` | None yet (candidate) |
| Matrix (Synapse) | `matrix.${DOMAIN}` | Native OIDC (Authelia) + native Synapse accounts (registration closed, admin-created) side by side |
| Element Web | `chat.${DOMAIN}` | — (client only; auth happens against Synapse) |
| LLDAP | internal-only (cluster + Tailscale) | — (identity backend) |
| Traefik | — | — (the proxy layer itself; owns public TLS directly) |
| CrowdSec | — (internal LAPI only) | — (edge protection layer for every app above; see Architecture Overview) |

For the full blow-by-blow of how this stack got here — every gotcha, every bug, every decision and why, across both the original Compose-era SSO rollout and the later Compose→Kubernetes migration — see **`migration_plan.md`**. A working log, not a polished doc, but the ground truth for anything not obvious from the manifests themselves.

Individual production incidents (real outages, root cause, fix, follow-up) are written up under **`docs/incidents/`** as they happen — `migration_plan.md` and `docs/architecture_record/` link the ones that directly shaped a design decision, but the directory itself is the full list.

## 🔒 Security Notes

- **Check for leftover direct `NodePort`/`hostPort` exposure when adding a new app.** Traefik reaches every app over the cluster network by Service name — a host port bypasses Authelia entirely regardless of how well the SSO side is configured. This bit the old Compose stack for real (Dozzle, Uptime Kuma, Calibre-web) and is worth checking on every new app's manifest.
- **Header-auth apps must never be reachable except through Traefik.** Trusting a `Remote-User`-style header means anyone who can reach the app's Service directly can forge it.
- **LLDAP's admin UI is intentionally never exposed publicly** — it manages every account in the system, including Authelia's own. It's reachable only cluster-internally or over the tailnet.
- Real secrets (LDAP bind passwords, OIDC client secrets, encryption keys) are applied directly to the cluster and are **not** committed to git — no SOPS/Sealed Secrets yet, so secret rotation is still an imperative, `kubectl`-driven step (see `migration_plan.md`'s "Known blockers" section).
- A pre-commit hook (`.githooks/pre-commit`, enabled via `git config core.hooksPath .githooks`) runs [gitleaks](https://github.com/gitleaks/gitleaks) against staged changes and blocks the commit if it finds anything secret-shaped. Requires `gitleaks` on `PATH` (`sudo apt install gitleaks`, or see the linked install docs) — the hook refuses to commit unscanned if it's missing. Bypass with `git commit --no-verify` only for confirmed false positives.
- **CrowdSec is edge protection, not an auth replacement.** It bans IPs after they trip a scenario (repeated failed logins, scanning, known-bad community IPs) — it doesn't gate access the way Authelia does. Apps not yet behind Authelia (Vaultwarden) still need their own login to actually be strong; CrowdSec just makes brute-forcing it much more expensive.

## ⚠️ Disclaimer

This is a **reference** repository reflecting a specific personal setup, including a real SSO/identity layer with real security implications — not a hardened, general-purpose product. Review every manifest under `k8s/apps/` and the Security Notes above before deploying anything from here, especially the auth-related pieces.

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
