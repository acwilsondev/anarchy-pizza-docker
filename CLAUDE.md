# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A GitOps reference for a real, live single-node k3s home server stack — not application code. There is no build, lint, or test suite; "correctness" here means a manifest that Argo CD will sync cleanly and that matches how the app actually behaves once live. Pushing to `main` is the deploy mechanism once Argo CD is bootstrapped (`kubectl apply -f k8s/argocd/root-app.yaml`), so changes under `k8s/apps/` take effect on the real cluster automatically (`prune: true`, `selfHeal: true`) — there is no staging environment.

## Working in this repo

- **Validate a Helm-based change before pushing**, the way past changes in this repo have been verified: `helm template <chart> -f k8s/apps/<app>/values.yaml` against the same chart/version pinned in that app's `application.yaml`, diffed against the previously-rendered output. There's no CI running this — it's a manual step.
- **Never commit secrets.** A pre-commit hook (`.githooks/pre-commit`, enabled once per clone via `git config core.hooksPath .githooks`) runs `gitleaks protect --staged` against `.gitleaks.toml` and refuses to commit if `gitleaks` isn't on `PATH`. Real secrets (LDAP bind passwords, OIDC client secrets, LAPI keys) are applied directly to the cluster with `kubectl` and never appear in git — see the `lapi.secrets`/`ignoreDifferences` pattern in `k8s/apps/crowdsec/application.yaml` for how an app is wired to reuse an existing in-cluster Secret via Helm's `lookup()` instead of having one committed.
- **Markdown is linted.** The same pre-commit hook also runs `markdownlint-cli2` (config in `.markdownlint.jsonc`/`.markdownlint-cli2.jsonc`) against staged `*.md` files and refuses to commit if `node_modules/.bin/markdownlint-cli2` isn't present — run `npm install` once per clone. `npm run lint:md` runs it manually against everything; `npm run lint:md:fix` autofixes what it can. Line-length (`MD013`) and strict table pipe-padding (`MD060`) are disabled since this repo's existing prose/tables predate the linter and don't follow either convention.
- **Renovate** (`renovate.json`) opens PRs for `k8s/apps/*/values.yaml` chart version bumps only — `helm-values` manager, weekly, nothing auto-merges. `vikunja-tagger`'s image tag is excluded (it's a commit SHA set by that app's own CI, not a version Renovate should touch).

## App definition pattern

Every directory under `k8s/apps/<app>/` is one Argo CD child `Application` (auto-discovered by the app-of-apps root at `k8s/argocd/root-app.yaml`, which watches `k8s/apps/` recursively — there is no per-app registration step). Two shapes:

- **Multi-source Helm app** (the norm): `application.yaml` declares two `sources` — the upstream chart (`repoURL`/`chart`/`targetRevision`) plus this repo itself referenced as `ref: values`, with `helm.valueFiles` pointing at `$values/k8s/apps/<app>/values.yaml` in the same directory. Compare `k8s/apps/dozzle/application.yaml` (generic `bjw-s-labs/app-template` chart) against `k8s/apps/vaultwarden/application.yaml` (an app-specific community chart) — same shape, different chart source. Adding a new app means creating this pair of files, matching an existing one as the template.
- **Plain-manifest app**: no `application.yaml`/Helm chart, just raw manifests picked up by the recursive root app (e.g. `k8s/apps/ingress/*.yaml` — Traefik `Middleware`/`Certificate`/`TLSStore` objects that don't belong to any single app's Helm release).

`bjw-s-labs/app-template` is the default chart for anything without its own decent upstream chart; an app-specific community chart is preferred when one exists and is actually usable (verify it renders/resolves before trusting an "official" label — this has bitten the migration before).

## Security architecture

Every app is reached only through Traefik (`Internet → Traefik → CrowdSec bouncer Middleware → Authelia → app`); a leftover direct `NodePort`/`hostPort` on any app's Service bypasses Authelia entirely and is the most common real mistake in this stack's history. Authelia (backed by LLDAP) gates apps via one of three patterns — forward-auth, header-auth, or native OIDC — chosen per-app by what it natively supports, not a single mechanism. Full detail, including which apps use which pattern, is in `docs/architecture/single-sign-on.md`.

## Docs layout — follow this when adding to it

- **`docs/architecture/`** — current-state description of the system, topic-named (no dates). Update these in place when the architecture actually changes.
- **`docs/architecture_record/`** — an immutable, dated decision log, one `YYYY-MM-DD-title.md` file per decision (why it was made, what broke, how it was verified). Never edit a past entry to reflect new reality — add a new dated entry and cross-link back, the way `2026-08-20-bring-crowdsec-under-gitops.md` references the blocker it closes in `2026-08-13-close-out-known-blockers.md`. `migration_plan.md` at the repo root is just an ordered index into this directory.
- **`docs/incidents/`** — real production outage post-mortems (detected/started/duration/impact, timeline, root cause, ruled-out causes, recommendations), independent of the architecture_record. Referenced from architecture_record entries where an incident directly shaped a decision (e.g. why the CrowdSec bouncer runs `crowdsecMode: live` instead of `stream`).

This structure is intentional and recent (split out of one long `migration_plan.md` and a README section) — don't collapse it back into inline README prose.
