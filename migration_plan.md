# Kubernetes / Helm / Argo CD Migration: Index

The full decision-by-decision record of moving this stack from Docker
Compose (14 apps, one `docker-compose.yml` per app, manually applied via
`update-all-apps.sh`) onto a single-node k3s cluster with Helm-packaged
apps and Argo CD doing GitOps sync. Each entry below is its own
self-contained record — the why, what was decided, what broke, how it was
verified — under `docs/architecture_record/`, in the order things actually
happened. This file is just the index.

1. [2026-08-10 — Migrate from Compose to k3s + Helm + Argo CD](docs/architecture_record/2026-08-10-migrate-from-compose-to-k3s-helm-argocd.md) — why, toolchain choice, known blockers, planned rollout order.
2. [2026-08-13 — Stand up k3s alongside Compose](docs/architecture_record/2026-08-13-stand-up-k3s-alongside-compose.md) — rollout step 1, no cutover yet.
3. [2026-08-13 — Prove the pattern on low-risk apps](docs/architecture_record/2026-08-13-prove-the-pattern-on-low-risk-apps.md) — rollout step 2/3: Dozzle, Uptime Kuma, SearXNG.
4. [2026-08-13 — Migrate the SSO-critical path](docs/architecture_record/2026-08-13-migrate-the-sso-critical-path.md) — rollout step 4: LLDAP → Authelia, parallel and isolated.
5. [2026-08-13 — Migrate remaining apps](docs/architecture_record/2026-08-13-migrate-remaining-apps.md) — rollout step 5: Vaultwarden, FreshRSS, Calibre-web, Open WebUI, Vikunja, Homarr, Matrix/Synapse + Element-web.
6. [2026-08-13 — Migrate real data](docs/architecture_record/2026-08-13-migrate-real-data.md) — backup/restore for every app with real data, not a fresh cutover.
7. [2026-08-13 — Wire up OIDC](docs/architecture_record/2026-08-13-wire-up-oidc.md) — Authelia as OIDC provider, per-app client config.
8. [2026-08-13 — Cut over to Traefik + cert-manager](docs/architecture_record/2026-08-13-cutover-traefik-and-cert-manager.md) — the actual cutover, the IPv6 detour, post-cutover verification.
9. [2026-08-13 — Close out the known migration blockers](docs/architecture_record/2026-08-13-close-out-known-blockers.md) — final status of every blocker from entry 1.
10. [2026-08-20 — Bring CrowdSec's k3s deployment under GitOps management](docs/architecture_record/2026-08-20-bring-crowdsec-under-gitops.md) — a post-cutover gap found and fixed during a docs pass.

Real production incidents (outages, root cause, fix, follow-up) are
tracked separately under `docs/incidents/`, not here — several of the
entries above reference specific ones where an incident directly shaped a
decision.

Old Traefik/Authelia SSO rollout history (the original NPM→Traefik
cutover on Compose) lives in git history as `archived/migration_plan.md`,
removed from the working tree in the 2026-08-20 repo cleanup along with
the rest of the Docker Compose configs it documents.
