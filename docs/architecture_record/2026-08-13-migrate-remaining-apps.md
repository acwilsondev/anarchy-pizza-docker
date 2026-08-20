# Migrate remaining apps (rollout step 5, part 1)

Done, 2026-08-13. First part of the full cutover — the whole stack now
runs live in k3s. Docker Compose is fully stopped (all containers,
including Traefik) — every compose file and every app's real data
directory is untouched on disk as an instant rollback
(`docker compose up -d` in any `apps/<app>/`), same posture as every step
before this one, but this is the first step where that rollback path
actually matters, since k3s is now the thing serving real traffic.

**Backups** of every real dataset touched during migration live at
`${STORAGE_ROOT}/backups/k3s-migration-2026-08-13/` (tarballs for
LLDAP/Vaultwarden/FreshRSS/Calibre-web/Homarr, `pg_dump` dumps for
Vikunja/Synapse) — taken before any stop-and-copy step, not after. See
`docs/architecture_record/2026-08-13-migrate-real-data.md` for how that
data actually got moved.

## Remaining apps migrated

Vaultwarden, FreshRSS, Calibre-web, Open WebUI, Vikunja, Homarr,
Matrix/Synapse + Element-web — all now in k3s, following the same
Argo CD Application-per-app pattern as
`docs/architecture_record/2026-08-13-stand-up-k3s-alongside-compose.md`,
`docs/architecture_record/2026-08-13-prove-the-pattern-on-low-risk-apps.md`,
and
`docs/architecture_record/2026-08-13-migrate-the-sso-critical-path.md`:

- **Vaultwarden** — `guerzon/vaultwarden` chart (actively maintained
  community chart, not app-template — already encodes Vaultwarden-
  specific correctness like the SQLite-vs-external-DB switch).
- **FreshRSS, Calibre-web, Open WebUI** — `app-template`, header-auth
  pattern. Open WebUI got `runtimeClassName: nvidia` +
  `nvidia.com/gpu: 1` (the GPU-passthrough blocker, now solved — see
  `docs/architecture_record/2026-08-13-close-out-known-blockers.md`).
  Calibre-web's book library is a `hostPath` straight at `MEDIA_ROOT`,
  not copied into a PVC.
- **Vikunja** — `app-template`, not its "official" chart
  (`kolaente.dev`, the maintainer's personal Gitea) — that chart repo
  had a broken TLS cert and was unreachable, same lesson as Authelia's
  chart in the SSO-critical-path step: verify a chart is actually usable
  before trusting an "official" label. One Application, two controllers
  (vikunja + postgresql) mirroring the one `docker-compose.yml`.
- **Homarr** — `app-template`. Dropped the `docker.sock` dashboard-
  widget feature (see the close-out-known-blockers doc) rather than
  building the RBAC'd k8s-API rework — not missed enough yet to justify
  it.
- **Matrix/Synapse + Element-web** — Synapse via
  `ananace-charts/matrix-synapse`, with its bundled Bitnami
  postgresql/redis subcharts disabled (Bitnami's free image tier has
  been getting deprecated/frozen since Aug 2025) in favor of two small
  separate `app-template` releases. Federation stays fully disabled —
  confirmed empirically (`/_matrix/federation/v1/version` → `404
  Unrecognized request`), not just configured and assumed. Real gotcha:
  the chart hardcodes `resources: [client, federation]` on the main
  listener with no values-level override; worked around via
  `extraConfig.listeners` landing as a second `listeners:` key in the
  rendered `homeserver.yaml`, which Synapse's YAML loader resolves using
  the *last* value for a duplicate key — verified against the actual
  rendered config and the running pod's behavior, not assumed.
