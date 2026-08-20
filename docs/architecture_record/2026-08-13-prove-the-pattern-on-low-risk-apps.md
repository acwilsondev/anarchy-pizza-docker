# Prove the pattern on low-risk apps: Dozzle, Uptime Kuma, SearXNG (rollout step 2)

Done, 2026-08-13. Second step of
`docs/architecture_record/2026-08-10-migrate-from-compose-to-k3s-helm-argocd.md`'s
rollout plan, following
`docs/architecture_record/2026-08-13-stand-up-k3s-alongside-compose.md`.

All three now run in k3s as `bjw-s/app-template` Helm releases (chart
v3.7.3), each its own Argo CD child Application under the app-of-apps root
— the pattern future migrations should follow. Fresh namespaces and
`local-path-provisioner` PVCs, not the live `STORAGE_ROOT` bind mounts, so
the Compose versions of these three keep running unmodified as the live
path. Verified functionally, not just Argo-CD-"Healthy":

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
only via `kubectl port-forward`, per "no cutover yet." That wiring, plus
sorting out SearXNG's limiter/trusted-proxy config for real, is scoped to
rollout step 5 (`docs/architecture_record/2026-08-13-cutover-traefik-and-cert-manager.md`),
not before.
