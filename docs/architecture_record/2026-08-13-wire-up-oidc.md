# Wire up OIDC for real (rollout step 5, part 3)

Done, 2026-08-13, as part of the full cutover
(`docs/architecture_record/2026-08-13-migrate-remaining-apps.md`).
`identity_providers.oidc` added to the k3s Authelia's config (second
`--config` file, same deep-merge pattern already proven in production —
see `archived/migration_plan.md` in git history), fresh `hmac_secret` +
4096-bit RSA key. Vikunja/Homarr/Matrix registered as clients, each with
its own correct `token_endpoint_auth_method` (Vikunja/Matrix:
`client_secret_post`, Homarr: `client_secret_basic` — not copy-pasted
from one to the others). Matrix's client secret couldn't go through the
Synapse chart's `extraSecrets` values field without landing in git, so
it rides in on the chart's own secret-injection mechanism instead (see
`k8s/apps/matrix-synapse/values.yaml` for the mechanics).

This is the OIDC wiring that
`docs/architecture_record/2026-08-13-migrate-the-sso-critical-path.md`
explicitly deferred (that step was forward-auth only, matching
Dozzle/Uptime Kuma/SearXNG).
