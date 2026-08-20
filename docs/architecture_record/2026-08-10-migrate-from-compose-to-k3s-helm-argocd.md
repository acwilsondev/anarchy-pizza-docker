# Migrate from Docker Compose to k3s + Helm + Argo CD

Started 2026-08-10. Goal: move the whole stack from Docker Compose (14
apps, one `docker-compose.yml` per app, manually applied via
`update-all-apps.sh`) onto a single-node Kubernetes cluster with
Helm-packaged apps and Argo CD doing GitOps sync — still one physical
server, no multi-node HA — without tearing down the working Compose
stack until each piece is proven, and without repeating the "no live
impact" mistake from the NPM→Traefik cutover (see the pre-2026-08-20 git
history for `archived/migration_plan.md`, removed from the tree in that
cleanup along with the rest of the Docker Compose configs).

## Why

Not chasing horizontal HA — it's still one box, and most of this stack
is single-instance stateful anyway (LLDAP, Authelia sessions, app DBs),
so extra replicas wouldn't add real redundancy. The actual goals, each
tied to a gap already hit for real in the Compose stack's history:

- **Self-healing on failed container/network setup.** Docker's boot-time
  container restore tries once and gives up on failure — this is exactly
  what took Authelia/LLDAP down for ~5.5 hours undetected on 2026-08-09
  (`docs/incidents/2026-08-09-lldap-authelia-outage.md`). Kubelet continuously
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
migration. Final status of each is in
`docs/architecture_record/2026-08-13-close-out-known-blockers.md`.

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
   (`docs/architecture_record/2026-08-13-stand-up-k3s-alongside-compose.md`)
2. Migrate stateless/low-risk apps first: Dozzle, Uptime Kuma, SearXNG.
3. Prove the Helm + Argo CD sync loop end-to-end on those before going
   further.
   (`docs/architecture_record/2026-08-13-prove-the-pattern-on-low-risk-apps.md`)
4. Migrate the SSO-critical path last and carefully: LLDAP → Authelia →
   everything gated behind it.
   (`docs/architecture_record/2026-08-13-migrate-the-sso-critical-path.md`)
5. Cut public traffic over only once every app is validated in k8s,
   keeping the Compose stack as an instant rollback the whole time —
   same posture used keeping `archived/npm`'s compose file and data around
   after the Traefik cutover.
   (`docs/architecture_record/2026-08-13-migrate-remaining-apps.md` onward)
