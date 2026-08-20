# Close out the known migration blockers

Done, 2026-08-13 (LLDAP's Tailscale exposure closed out slightly later
the same day, post-cutover). Final status of every blocker listed in
`docs/architecture_record/2026-08-10-migrate-from-compose-to-k3s-helm-argocd.md`:

- **GPU passthrough** — solved. `nvdp/nvidia-device-plugin` installed;
  needed a manual `nvidia.com/gpu.present=true` node label since
  Node Feature Discovery isn't running (the chart's default node
  affinity requires an NFD-set label otherwise).
- **LLDAP's Tailscale exposure** — solved, 2026-08-13 (post-cutover).
  Tailscale Kubernetes Operator (`tailscale/tailscale-operator`, OAuth
  client + `tagOwners` ACL set up directly by the user — kept out of
  git/session context entirely), exposing a dedicated
  `lldap-tailscale` Service (`k8s/apps/lldap/tailscale-service.yaml`,
  admin UI port 17170 only — not the raw LDAP port Authelia uses
  internally) via the `tailscale.com/expose`/`tailscale.com/hostname`
  annotations. Matches the original Compose posture (admin-UI-only,
  never on the public port) rather than the exact same mechanism.
  Real snag hit setting it up: the OAuth client creation UI didn't show
  a tag-selection step at all in the current admin console (differs
  from older docs) — turned out not to matter, since tailnet
  owners/admins get implicit access to any tag without needing to pick
  one explicitly. The actual fix was just making sure the `tagOwners`
  ACL edit was saved *before* generating the OAuth client. (Argo CD's
  own UI was exposed the same way and around the same time, via
  `k8s/apps/argocd/tailscale-service.yaml`.)
- **Traefik's `docker.sock` mount** — gone, as expected, replaced by the
  Kubernetes provider.
- **Homarr's `docker.sock` widget** — dropped for now (see
  `docs/architecture_record/2026-08-13-migrate-remaining-apps.md`),
  revisit if actually missed.
- **ACME state** — solved via cert-manager + a `Certificate`/`TLSStore`,
  not a raw `acme.json` PVC (see
  `docs/architecture_record/2026-08-13-cutover-traefik-and-cert-manager.md`).
- **Storage tiers** — mixed, deliberately: `local-path-provisioner` PVCs
  for small/medium app state, `hostPath` straight at the real
  `STORAGE_ROOT` paths for large bulk data (Calibre-web's books,
  Open WebUI's Ollama models) to keep it on the correct physical disk.
- **Secrets outside git** — still unsolved as a *general* GitOps
  mechanism (no SOPS/Sealed Secrets yet); every secret this whole
  migration touched was applied directly to the cluster via `kubectl`,
  never committed — consistent, but still imperative rather than
  declarative. Worth solving properly before the next round of secret
  rotation or a second node ever enters the picture. (This is also
  exactly the gap that let CrowdSec's own deployment go untracked — see
  `docs/architecture_record/2026-08-20-bring-crowdsec-under-gitops.md`.)
