# Cut over to Traefik + cert-manager in k3s (rollout step 5, part 4)

Done, 2026-08-13 — the actual cutover, the last part of the full-cutover
step alongside
`docs/architecture_record/2026-08-13-migrate-remaining-apps.md`,
`docs/architecture_record/2026-08-13-migrate-real-data.md`, and
`docs/architecture_record/2026-08-13-wire-up-oidc.md`.

Traefik deployed via the official chart (not k3s's bundled one, still
disabled) — `hostPort` 80/443, matching exactly how the Compose Traefik
it replaced already worked, since ServiceLB is also disabled and this
is single-node. cert-manager owns certificate issuance (not Traefik's
own ACME resolver, which would race it) via a `ClusterIssuer` + one
multi-SAN `Certificate` covering all 12 app domains, referenced through
a `TLSStore` named `default` so every app's `IngressRoute` just sets
`tls: {}` without a per-namespace copy of the cert secret. Two real bugs
caught before any real traffic was affected: cross-namespace
`Middleware` references are disabled by default in the chart (would have
meant zero Authelia/CrowdSec protection on every route despite the
config looking correct), and the http→https redirect field was nested
one level too shallow (caught by Argo CD's own schema validation).

**IPv6 detour, reverted:** cert-manager's HTTP-01 validation failed for
all 12 domains — DNS was correct, but the fresh k3s cluster is
single-stack IPv4 internally (`10.42.0.0/24` pod CIDR), unlike Docker's
dual-stack-by-default port publishing, so `hostPort` had no IPv6 pod
address to forward to. Attempted a live dual-stack reconversion
(`cluster-cidr`/`service-cidr` config + node re-registration); the
Kubernetes API forbids changing a node's `podCIDRs` except from empty,
and simply deleting the Node object didn't produce a truly empty one
(k3s appears to cache the allocation internally) — this caused a real
~15-minute k3s control-plane crash loop (data plane / running pods were
never affected). Reverted the dual-stack config, confirmed 30+ seconds
of stable `k3s.service`, then took the simpler path: removed the AAAA
DNS records so validation happens over IPv4 only (already proven
working). Real dual-stack k3s networking, if wanted later, needs to be
decided at cluster bootstrap, not retrofitted onto a live one.

Verified post-cutover, not just "Traefik is Running": all 12 domains
return the expected HTTP code (302 for forward-auth apps, 200 for
native-OIDC/Vaultwarden) with a certificate that validates without
`-k`/`--insecure`, i.e. a real trusted Let's Encrypt cert, not
self-signed.

Old Traefik/Authelia SSO rollout history (the original NPM→Traefik
cutover on Compose) lives in git history as `archived/migration_plan.md`,
removed from the working tree in the 2026-08-20 repo cleanup along with
the rest of the Docker Compose configs it documents.
