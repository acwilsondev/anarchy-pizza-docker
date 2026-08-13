# Kubernetes / Helm / Argo CD Migration Notes

Started 2026-08-10. Goal: move the whole stack from Docker Compose (14
apps, one `docker-compose.yml` per app, manually applied via
`update-all-apps.sh`) onto a single-node Kubernetes cluster with
Helm-packaged apps and Argo CD doing GitOps sync — still one physical
server, no multi-node HA — without tearing down the working Compose
stack until each piece is proven, and without repeating the "no live
impact" mistake from the NPM→Traefik cutover (see
`archived/migration_plan.md`).

## Why

Not chasing horizontal HA — it's still one box, and most of this stack
is single-instance stateful anyway (LLDAP, Authelia sessions, app DBs),
so extra replicas wouldn't add real redundancy. The actual goals, each
tied to a gap already hit for real in the Compose stack's history:

- **Self-healing on failed container/network setup.** Docker's boot-time
  container restore tries once and gives up on failure — this is exactly
  what took Authelia/LLDAP down for ~5.5 hours undetected on 2026-08-09
  (`incidents/2026-08-09-lldap-authelia-outage.md`). Kubelet continuously
  reconciles desired vs. actual state instead of a single restore attempt.
- **Real rolling updates.** `update-all-apps.sh` currently does
  `pull && up -d --remove-orphans`, which recreates the container in
  place — a brief hard-restart on every update, despite the README's
  "Zero-Downtime Updates" claim. Kubernetes rolling updates + readiness
  probes actually deliver that.
- **GitOps instead of hand-run commands.** Every change logged in
  `archived/migration_plan.md` was a manually-run `docker compose`
  command or (in one case) an untracked NPM-UI click. Argo CD watching
  this repo closes that gap — desired state lives in git, drift is
  visible, sync is automatic or manually gated (TBD).

## Toolchain (decided, not yet installed)

- **k3s** — single binary, ships containerd + Traefik + ServiceLB
  built in. Chosen over full kubeadm or MicroK8s for being purpose-built
  for "one server, not a real cluster."
- **Helm** — upstream charts where they already exist and are decent
  (Authelia, Vaultwarden, Matrix/Synapse, Vikunja); a shared library
  chart (leaning `bjw-s/app-template`, the standard homelab pattern) for
  everything else, rather than hand-writing raw manifests per app.
- **Argo CD** — single in-cluster instance, pointed at this repo.

## Known blockers / carry-overs from the Compose stack

Not yet solved — listed up front so the plan doesn't quietly drop them
partway through, the way a couple of things nearly did in the last
migration.

- **GPU passthrough** for `apps/webui` (Ollama) — needs the NVIDIA
  device plugin for Kubernetes on the node.
- **LLDAP's Tailscale exposure** — currently `127.0.0.1` bind +
  `tailscale serve` (fixed after the Aug 9 incident, see
  `apps/lldap/docker-compose.yml`). Needs an equivalent in k8s (sidecar,
  or the official Tailscale k8s operator). Do not regress to binding a
  service directly to the Tailscale IP — that's the exact boot-race bug
  already fixed once.
- **Traefik's `docker.sock` mount goes away**, replaced by the
  Kubernetes provider — net security improvement, no action needed
  beyond confirming the Kubernetes/Ingress provider config.
- **Homarr's `docker.sock` mount** for its dashboard widgets has no
  clean k8s equivalent — likely loses that feature or needs a
  Kubernetes-API-based rework (RBAC'd ServiceAccount instead of the raw
  socket).
- **ACME state** (`acme.json`) → a PVC, or switch to cert-manager
  (more idiomatic in k8s; Traefik would stay as ingress controller
  either way since k3s ships it by default).
- **Bind-mount storage tiers** (`gold`/`silver`/`bronze` under
  `STORAGE_ROOT`) → `hostPath` or k3s's built-in
  `local-path-provisioner`. Fine for staying single-node.
- **Secrets currently live host-only, outside git**
  (`${STORAGE_ROOT}/silver/*/secrets/`) — need SOPS or Sealed Secrets to
  get real GitOps value from Argo CD without committing plaintext.

## Planned rollout order

Mirrors the NPM→Traefik playbook that worked last time — prove the
pattern on low-risk apps before touching the SSO-critical path, and keep
a working rollback available at every step:

1. Stand up k3s alongside the existing Docker stack — different ports,
   no cutover yet, Compose stack stays the live path throughout.
2. Migrate stateless/low-risk apps first: Dozzle, Uptime Kuma, SearXNG.
3. Prove the Helm + Argo CD sync loop end-to-end on those before going
   further.
4. Migrate the SSO-critical path last and carefully: LLDAP → Authelia →
   everything gated behind it.
5. Cut public traffic over only once every app is validated in k8s,
   keeping the Compose stack as an instant rollback the whole time —
   same posture used keeping `apps/npm`'s compose file and data around
   after the Traefik cutover.

## Status as of 2026-08-13

Step 1 (stand up k3s alongside Compose) done. k3s (Traefik/ServiceLB
disabled to avoid the port 80/443 conflict), Helm, and Argo CD are
installed and running on the same box. Argo CD watches this repo
(`k8s/apps/`, app-of-apps root at `k8s/argocd/root-app.yaml`, read-only
deploy key) with automated sync + prune + self-heal. The GitOps loop was
proven end-to-end with a throwaway smoke-test app — pushed, synced,
served traffic, then removed from git and auto-pruned from the cluster
— and has since been deleted, leaving `k8s/apps/` empty and ready for
the first real migration.

The Compose stack was never touched: all 18 containers stayed up and
were not restarted or reconfigured at any point during this step.

Step 2 (migrate Dozzle, Uptime Kuma, SearXNG) also done. All three now
run in k3s as `bjw-s/app-template` Helm releases (chart v3.7.3), each its
own Argo CD child Application under the app-of-apps root — the pattern
future migrations should follow. Fresh namespaces and
`local-path-provisioner` PVCs, not the live `STORAGE_ROOT` bind mounts,
so the Compose versions of these three keep running unmodified as the
live path. Verified functionally, not just Argo-CD-"Healthy":

- **Dozzle** — `hostPath`-mounts the real `/var/run/docker.sock`; logs
  confirm `Connected to Docker` and it sees the actual live containers.
- **Uptime Kuma** — serving its first-run setup flow on a fresh PVC, as
  expected for an empty database.
- **SearXNG + Valkey** — two controllers in one Helm release. Hit one
  real bug along the way: `service.valkey.nameOverride` in app-template
  doesn't produce a plain override — the actual Service name came out as
  `searxng-searxng-valkey`, not `searxng-valkey` as assumed. Fixed by
  matching `SEARXNG_VALKEY_URL` to the real object name instead of the
  assumed one. Confirmed connected (no more `ConnectionError` in logs).
  Direct `curl` against it returns 429 from its bot-detection limiter,
  which doesn't trust forwarded-IP headers without a reverse proxy in
  front — expected until Traefik actually sits in front of it at cutover,
  not a defect in this step.

None of these three are wired to Traefik/Authelia/DNS yet — reachable
only via `kubectl port-forward`, per "no cutover yet." That wiring,
plus sorting out SearXNG's limiter/trusted-proxy config for real, is
scoped to rollout step 5 (cutover), not before.

Step 4 (LLDAP → Authelia, the SSO-critical path) also done — the exact
stack behind the Aug 9 outage, handled as "last and carefully" as
promised. **Fully parallel and isolated, not a cutover**: fresh
namespaces (`lldap`, `authelia`), fresh PVCs, entirely fresh secrets, and
synthetic test identities (`testadmin`/`testuser`/`authelia` under
`@k3s-test.anarchy.pizza`) — no shared state whatsoever with the real
`aaron`/`steph` accounts or the live Compose `lldap`/`authelia` data.
Used `bjw-s/app-template` for both instead of Authelia's official chart
(`charts.authelia.com` is marked beta/breaking-changes-prone and its
values schema wasn't pinned down confidently in the time available —
not worth the risk on this component; deviates from the toolchain note,
worth revisiting with more research time before the real cutover).

Verified end-to-end with the *exact same technique* already proven in
`archived/migration_plan.md`'s incident history (`/api/firstfactor` then
`/api/verify` with the resulting session cookie), not just "pods are
Running":
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
later for Vikunja/Homarr/Matrix, not this step. No Tailscale exposure of
LLDAP's admin UI in k8s either. Neither is wired to Traefik, DNS, or the
previously-migrated apps — that wiring is the actual cutover.

Next: rollout step 5 — cut public traffic over, once every app
(including sorting out SearXNG's limiter/trusted-proxy config, OIDC for
the native-OIDC apps, and Tailscale exposure for LLDAP) is validated in
k8s, keeping the Compose stack as an instant rollback throughout. Old
Traefik/Authelia SSO rollout history archived to
`archived/migration_plan.md`.
