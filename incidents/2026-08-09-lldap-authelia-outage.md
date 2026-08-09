# 2026-08-09: lldap network loss took down Authelia, 404s on all apps

- **Detected:** 2026-08-09 ~09:22 MDT (user report: "getting 404 on all apps")
- **Started:** 2026-08-09 04:00 MDT (system reboot)
- **Duration:** ~5h22m undetected
- **Impact:** Every app routed through Traefik with the `authelia@docker` forward-auth middleware returned 404 instead of serving/redirecting to login. `synapse`, `synapse-postgresql`, `vaultwarden`, `element-web`, and other containers not gated by Authelia were unaffected and stayed healthy throughout.

## Timeline (times in MDT)

| Time | Event |
|---|---|
| 04:00:01 | `unattended-upgrades` triggers a full system reboot (an NVIDIA driver update fired `nvidia-cdi-refresh.path`, a strong signal a driver package needed a reboot). systemd stops every service, including `docker.service` and `tailscaled.service`, within the same second. |
| 04:00:01 | dockerd shuts down. Because the daemon itself is shutting down (`daemonShuttingDown=true`), its restart-policy engine explicitly skips restarting any container — this is normal and by design. |
| ~04:00:xx | System reboots. `tailscaled` and `docker.service` both start at roughly the same point in boot. `tailscaled` re-authenticates to the tailnet and re-acquires its address on `tailscale0` — this takes a few seconds, it is not instant. |
| ~04:00:xx | dockerd's boot-time container **restore** step (a single attempt per container, distinct from the crash-and-retry loop used later) tries to recreate `lldap`, which hard-binds its admin-UI port to the Tailscale IP (`${TAILSCALE_IP}:17170:17170`). `tailscale0` does not yet have that address assigned. Port binding fails: `cannot assign requested address`. |
| ~04:00:xx | Because the failure is in network/endpoint setup (not inside the container process), dockerd does not queue a retry the way it does for a process crash. The partially-created network endpoint is rolled back, dropping `lldap`'s attachment to the `anarchy-pizza` Docker network entirely. `lldap` is left `Exited`, `RestartCount: 0`. |
| ~04:00:xx onward | `authelia` (which restored fine — it doesn't bind to any host port) runs its startup checks, tries to dial `ldap://lldap:3890`, fails DNS resolution (lldap is gone from the network), and exits fatally. Its restart policy retries this every ~60s, failing identically each time — a genuine crash loop, now running for the rest of the incident. |
| ~04:00:xx – 09:22 | Every Traefik router using the `authelia@docker` middleware fails its forward-auth check against a dead backend and returns 404. No alerting caught this. |
| 09:22 | User reports 404s on all apps. |
| 09:2x | Diagnosis: `docker ps` shows `lldap` `Exited (128)`, `authelia` `Restarting`. `docker logs authelia` shows fatal LDAP dial failures. `docker inspect lldap` shows the exit error: `failed to bind host port 100.118.184.115:17170/tcp: cannot assign requested address`. |
| 09:2x | `tailscale status` confirms the tailnet IP is present and stable now — the failure was a one-time boot race, not an ongoing condition. |
| 09:2x | `docker start lldap` brings the process back up (health check passes — it only checks the LDAP port from inside the container) but `docker inspect lldap` shows `NetworkSettings.Networks: {}` — confirms the network attachment was dropped, not just the process. `authelia` still fails to resolve `lldap` afterward. |
| 09:2x | `docker network connect anarchy-pizza lldap` manually re-attaches the container to the Docker network. `authelia`'s next restart-policy cycle (already looping on its own, ~60s interval) succeeds immediately: `Startup complete`. |
| 09:2x | Verified via `curl -H "Host: uptime.anarchy.pizza" https://localhost/` → `302` (Authelia login redirect) instead of `404`. All 15 containers confirmed `Up`/`healthy`. |
| ~09:23 | `journalctl` around 04:00 MDT confirms the reboot signature (`Stopped .../Started ...` for every system timer within the same ~40s window) and the exact `ShouldRestart failed ... daemonShuttingDown=true` / `cannot assign requested address` sequence for `lldap`, corroborating the above. |

## Root cause

Two independent gaps compounded:

1. **Docker's boot-time container restore does not retry a failed network/port setup.** A container whose process crashes while the daemon is already running gets retried per its restart policy (with `RestartCount` incrementing). A container that fails to attach to its network *during the daemon's own startup restore* gets one attempt, and on failure is left `Exited` with its network endpoint torn down — nothing brings it back without manual intervention.
2. **`lldap`'s host port was hard-bound to a specific Tailscale IP** (`${TAILSCALE_IP}:17170:17170`), which only exists once `tailscaled` has re-established its tailnet connection after boot. Docker's container-restore step raced `tailscaled`'s own boot sequence and lost.

`authelia` behaved correctly given the circumstances — a hard startup-check failure and continuous retry is reasonable *if* the thing it depends on eventually comes back. The actual defect was entirely upstream, in `lldap` never coming back on its own.

No monitoring caught any of this for ~5.5 hours; it was only noticed because a user hit the apps directly.

## What did *not* cause this (ruled out)

- Not an OOM kill (`OOMKilled: false`).
- Not a `docker stop`/manual stop (`hasBeenManuallyStopped=false`).
- Not a recurring/ongoing Tailscale flap — `tailscale status` was stable and correct at diagnosis time; this was a one-shot boot race.
- Not caused by `depends_on` / compose ordering — `depends_on` only affects `docker compose up` sequencing at initial startup and would not have changed anything here, since both containers were already running for days before the reboot, and `authelia`'s own restart-policy loop (independent of any compose dependency) is what actually picked up the fix once `lldap`'s network was restored.

## Recommendations

- [x] **Stop hard-binding `lldap`'s admin UI to the Tailscale IP.** Bind it to `127.0.0.1:17170` (always available, no race) and expose it on the tailnet via `tailscale serve --tcp=17170`, which is owned by `tailscaled` itself and persists across reboots independent of Docker's boot timing. This removes the race condition entirely rather than just narrowing its window.
- [x] **Add a boot-time watchdog** that, shortly after boot, finds any container with restart policy `unless-stopped`/`always` sitting `Exited` and recovers it via `docker compose up -d` (not `docker start`, which does not reattach a dropped network endpoint — confirmed during this incident). Implemented as a `@reboot` entry in the user crontab (no root required) rather than a systemd unit, for simplicity.
- [x] **Order `docker.service` after `tailscaled.service`** via a systemd drop-in (`systemd/docker-after-tailscaled.conf`, installed at `/etc/systemd/system/docker.service.d/override.conf`), so Docker's boot-time container restore doesn't start until Tailscale has had a chance to come up. This is defense-in-depth for any *other* service that might someday bind to a Tailscale address at boot — the `lldap` fix above already eliminates this specific incident's trigger.
- [ ] **Uptime Kuma monitor for `lldap`/`authelia`** — explicitly deferred. There is an ongoing, separate intermittent issue that would make this noisy right now; revisit once that's resolved.

## Follow-up

All fixes applied and verified 2026-08-09, except the deferred Uptime Kuma monitor above.
