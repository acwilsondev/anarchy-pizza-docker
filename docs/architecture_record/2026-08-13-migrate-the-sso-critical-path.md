# Migrate the SSO-critical path: LLDAP → Authelia (rollout step 4)

Done, 2026-08-13 — the exact stack behind the Aug 9 outage
(`docs/incidents/2026-08-09-lldap-authelia-outage.md`), handled as "last and
carefully" as promised in
`docs/architecture_record/2026-08-10-migrate-from-compose-to-k3s-helm-argocd.md`.
(Step 3 was proving the sync loop, folded into
`docs/architecture_record/2026-08-13-prove-the-pattern-on-low-risk-apps.md`.)

**Fully parallel and isolated, not a cutover**: fresh namespaces (`lldap`,
`authelia`), fresh PVCs, entirely fresh secrets, and synthetic test
identities (`testadmin`/`testuser`/`authelia` under
`@k3s-test.anarchy.pizza`) — no shared state whatsoever with the real
`aaron`/`steph` accounts or the live Compose `lldap`/`authelia` data. Used
`bjw-s/app-template` for both instead of Authelia's official chart
(`charts.authelia.com` is marked beta/breaking-changes-prone and its
values schema wasn't pinned down confidently in the time available — not
worth the risk on this component; deviates from the toolchain note, worth
revisiting with more research time before the real cutover).

Verified end-to-end with the *exact same technique* already proven in
`archived/migration_plan.md`'s incident history (git history only now —
see `docs/architecture_record/2026-08-10-migrate-from-compose-to-k3s-helm-argocd.md`;
`/api/firstfactor` then `/api/verify` with the resulting session cookie),
not just "pods are Running":

- `kubectl exec ... /app/bootstrap.sh` output confirmed groups
  (`admins`, `users`) and users (`testadmin`, `testuser`, `authelia` in
  `lldap_strict_readonly`) were actually created, not just that the
  command exited 0.
- Authelia crash-looped 3 times immediately after first sync — expected
  and correct, since bootstrap hadn't run yet and the `authelia` LDAP
  bind failed with "Invalid Credentials." Self-healed on its own once
  bootstrap ran, no manual `docker network connect`-style intervention
  needed this time.
- `testadmin` → `200` on `dozzle.anarchy.pizza`, `testuser` → `403` on
  the same domain, `testuser` → `200` on a wildcard-only domain —
  matches the `aaron`/`testuser` pattern from the archived precedent
  exactly, proving LDAP bind, group lookup, and `access_control`
  evaluation all actually work together in k3s.
- Two verification-tooling gotchas hit and fixed along the way (not bugs
  in the actual config): `X-Original-URL` is nginx's forward-auth header
  convention, not Traefik's — needed `X-Forwarded-Proto`/`-Host`/`-Uri`
  instead, matching this repo's actual Traefik middleware config. And
  curl's cookie jar enforces domain-matching against the real connection
  target, not a spoofed `Host` header, so it silently dropped the
  session cookie until captured and replayed manually via `-H "Cookie:
  ..."`.

No OIDC (`identity_providers`) in this k3s copy — forward-auth only,
matching what Dozzle/Uptime Kuma/SearXNG actually use; OIDC is needed
later for Vikunja/Homarr/Matrix, not this step (see
`docs/architecture_record/2026-08-13-wire-up-oidc.md`). No Tailscale
exposure of LLDAP's admin UI in k8s either at this point (see
`docs/architecture_record/2026-08-13-close-out-known-blockers.md`).
Neither is wired to Traefik, DNS, or the previously-migrated apps — that
wiring is the actual cutover
(`docs/architecture_record/2026-08-13-cutover-traefik-and-cert-manager.md`).
