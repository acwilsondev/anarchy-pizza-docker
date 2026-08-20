# Request path and edge protection

```text
Internet → Traefik (public TLS via Let's Encrypt/cert-manager, ports 80/443)
              → CrowdSec bouncer (shared Middleware, referenced from every IngressRoute)
                  → Authelia (forward-auth or OIDC, as needed)
                      → the app
```

Traefik owns the public edge directly and terminates TLS itself, via a
`Certificate`/`ClusterIssuer` through cert-manager rather than Traefik's
own built-in ACME resolver (running both against the same domains would
race each other). Every app is reachable only through Traefik — an app
with a leftover direct `NodePort`/`hostPort` bypasses Authelia entirely
(see the Security Notes in the main README; this bit the old Compose
stack in practice, more than once, and is an explicit thing to check on
any new app).

**Edge protection**: [CrowdSec](https://www.crowdsec.net/)
(`k8s/apps/crowdsec/`) reads pod logs natively through the Kubernetes API
(its own DaemonSet-based acquisition) and feeds ban decisions to a shared
Traefik `Middleware` referenced from every app's `IngressRoute` — every
router gets it automatically. It runs ahead of Authelia's own login-form
brute-force protection and is the only thing guarding apps that don't sit
behind Authelia yet (Vaultwarden). Enrolled in CrowdSec's community
blocklist (CAPI). See
`docs/architecture_record/2026-08-20-bring-crowdsec-under-gitops.md` for
how this deployment is actually managed and what's gone wrong with it in
practice.
