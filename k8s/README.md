# Kubernetes / Helm / Argo CD layout

Mirrors `apps/<app>/docker-compose.yml` at the repo root, but for the k3s
side of the migration described in `migration_plan.md`. This directory is
what Argo CD syncs — nothing here is applied by hand once the root app is
bootstrapped.

- `argocd/root-app.yaml` — the single Argo CD `Application` (app-of-apps
  root) that watches `k8s/apps/` on `main` and auto-syncs everything under
  it. Applied once, by hand, to bootstrap Argo CD itself:
  `kubectl apply -f k8s/argocd/root-app.yaml`.
- `apps/<app>/` — one directory per migrated app, each either plain
  Kubernetes manifests or a Helm chart + values file, depending on what
  that app needs. One Argo CD `Application` per app, same as one
  `docker-compose.yml` per app on the Compose side.

Rollout order, blockers, and the reasoning behind the toolchain choices
live in `migration_plan.md`, not here — this file only documents the
directory layout.
