# Bring CrowdSec's k3s deployment under GitOps management

Found and fixed 2026-08-20, during a docs cleanup pass — not in response
to a live incident. CrowdSec's k3s deployment was `helm install`'d by
hand directly against the cluster back on 2026-08-13, during the main
cutover (`docs/architecture_record/2026-08-13-cutover-traefik-and-cert-manager.md`),
but that install was never committed to this repo. It ran live, enforcing
real bouncer decisions in Traefik, for a week with no Argo CD
`Application` and no record of it anywhere in git — exactly the kind of
drift `docs/architecture_record/2026-08-13-close-out-known-blockers.md`
flagged as still-unsolved under "secrets outside git."

Two more real problems turned up investigating it, both silent:

- **`crowdsec-agent` DaemonSet had been crash-looping for 100+ hours.** The
  pod's name is stable (`crowdsec-agent-<suffix>`), and the init container
  templates its LAPI machine username from that pod name. It registered
  fine once on 2026-08-16, then a later pod restart tried to register the
  same machine name again → `403 user already exists`, with no idempotency
  check to look for existing credentials first — 1229 restarts before
  anyone noticed. Fixed by deleting the stuck pod so the DaemonSet
  recreated it under a fresh name.
- **That uncovered a second, unrelated bug**: the new pod then failed with
  `could not create fsnotify watcher: too many open files` —
  `fs.inotify.max_user_instances` was the node's stock default (128),
  shared across every root process on this single-node host (k3s,
  containerd, and reload-watchers for ~18 other Argo CD apps). Raised to
  1024 (`max_user_instances`) / 524288 (`max_user_watches`) via
  `/etc/sysctl.d/99-inotify.conf`. Agent is now `1/1 Running`, 0 restarts,
  both the Traefik and Vaultwarden log sources attached.

The net effect while this sat broken: the bouncer middleware kept enforcing
fine (LAPI stayed healthy the whole time), but fresh local log-based
detection was dead — CrowdSec was coasting on the CAPI community blocklist
and whatever was already cached, not actually watching this stack's own
logs. (Notably, the middleware itself never had a deny-by-default gap the
way it did in `docs/incidents/2026-08-10-crowdsec-stream-mode-startup-blackout.md`
— that incident is why the bouncer runs `crowdsecMode: live`, querying LAPI
per-request instead of a synced local cache, so this outage stayed silent
rather than 403ing real traffic.)

Fixed for real in commit `d38e18c`: `k8s/apps/crowdsec/application.yaml` +
`values.yaml` added, Argo CD adopted the existing release cleanly (`Synced`/
`Healthy`, no unexpected diffs against the hand-installed state). `lapi.secrets`
is deliberately left unset in values.yaml — the chart falls back to Helm's
`lookup()` to reuse the already-existing `crowdsec-lapi-secrets` Secret
in-cluster rather than generating a new one (this repo is public, so the
actual secret can never be committed), with `ignoreDifferences` on that
Secret's `/data` in the `Application` spec since `lookup()` is known to
behave inconsistently during Argo CD's diff/selfHeal passes and could
otherwise rotate the secret out from under the already-registered bouncer.

Same lesson as the rest of this migration: verified live, not just
"Synced" — the bouncer's most recent valid LAPI pull landed *after* the
LAPI pod recycled during this fix, confirming the secret actually survived
intact.
