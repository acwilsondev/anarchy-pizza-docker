# Single sign-on: three patterns, by what the app supports

Authelia is backed by LLDAP (LDAP identity store, cluster-internal only,
reachable for administration via `kubectl port-forward` or the Tailscale
Kubernetes Operator — never exposed on the public Traefik path) and is
itself also configured as an OIDC provider. Which pattern an app gets
depends on what it natively supports:

| Pattern | How it works | Apps using it |
|---|---|---|
| **Forward-auth gate** | Traefik calls Authelia before every request; the app itself has no auth (or its own login is disabled) | Dozzle, Uptime Kuma, SearXNG |
| **Header-auth SSO** | Authelia forwards a trusted header (`Remote-User`/`Remote-Email`); the app trusts it directly — real single login | FreshRSS, Calibre-web, Open WebUI |
| **Native OIDC** | The app talks to Authelia's OIDC endpoints itself; no forward-auth middleware needed | Vikunja, Homarr, Matrix (alongside native accounts — see `k8s/apps/matrix-synapse/values.yaml`) |

Access is role-based via two LDAP groups — `admins` (full access) and
`users` (deny-listed from a few apps) — not per-app allow-lists.

Apps not yet on this pattern: **Vaultwarden** (has its own native OIDC
support, not yet wired up — it is on Traefik/TLS now, just not behind
Authelia), and **LLDAP** (internal-only by design, see above).

See `docs/architecture_record/2026-08-13-migrate-the-sso-critical-path.md`
and `docs/architecture_record/2026-08-13-wire-up-oidc.md` for how this was
actually built and verified.
