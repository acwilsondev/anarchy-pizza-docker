# 2026-08-10: CrowdSec bouncer briefly 403'd all traffic during initial rollout

- **Detected:** 2026-08-10 ~19:52 MDT (live, while deploying the crowdsec bouncer for the first time)
- **Started:** 2026-08-10 19:51:44 MDT
- **Duration:** ~47s
- **Impact:** Real requests from at least one real client IP got `403` from Traefik across every app it tried (FreshRSS, Dozzle, Homarr) during the window. Self-resolved with no intervention beyond the rollout already in progress. No lasting effect.

## Timeline (times in MDT)

| Time | Event |
|---|---|
| 19:51:28 | Traefik restarted to load the new crowdsec bouncer plugin (`crowdsecMode: stream`). Plugin's first decision-stream sync (`.../v1/decisions/stream?startup=true`) raced the crowdsec container itself, which had *just* been recreated seconds earlier for an unrelated fix — `connection refused`. |
| 19:51:44 – 19:52:30 | Real client requests to `news.anarchy.pizza`, `dozzle.anarchy.pizza`, `homarr.anarchy.pizza` return `403` from Traefik's access log, `RouterName` present (so the request reached routing, not TLS/DNS), no origin service ever hit (`OriginStatus: 0`) — consistent with the bouncer middleware denying before the app. |
| 19:52:15 | `cscli bouncers list` shows a successful `Last API pull` for the first time — the stream sync completed. |
| 19:52:31 onward | Same client IP, same apps: `200`/`302` from here on, no further `403`s. |
| — | `cscli decisions list -i <the client IP>` confirmed **no active decision** for it at any point — this was never a real ban, just the plugin's own state being unknown. |

## Root cause

`crowdsecMode: stream` keeps a local cache of *banned* IPs only, refreshed periodically from crowdsec's LAPI, and defaults to denying all traffic until its **first** sync completes — there's no cached state yet to say a request is clean. That first sync depends on crowdsec's LAPI actually being up and reachable, which briefly wasn't true here because the crowdsec container had just been recreated (for an unrelated `traefik.http.services.crowdsec.loadbalancer.server.port` fix, see `apps/crowdsec/docker-compose.yml`) at nearly the same moment Traefik itself restarted to load the plugin. Once the sync succeeded, deny-by-default lifted and traffic passed normally.

This isn't a one-off startup-order mistake specific to this rollout — it's `stream` mode's designed behavior on *every* cold start, including routine `update-all-apps.sh` runs that restart both containers.

## What did *not* cause this (ruled out)

- Not a real ban — no matching decision existed in crowdsec at any point during or after.
- Not a Traefik routing/TLS/DNS problem — requests reached the correct router (`RouterName` populated in the access log) and got a clean `403`, not a connection failure.
- Not specific to any one app — it hit every app the same client tried during the window, and stopped for all of them at the same moment the sync completed.

## Recommendations

- [x] **Switched `crowdsecMode` from `stream` to `live`** in `apps/crowdsec/docker-compose.yml`. `live` queries crowdsec's LAPI per-request instead of relying on a synced local cache, so there's no "state unknown, deny everything" window on startup — at the cost of a per-request round trip to `crowdsec:8080` over the internal Docker network (negligible on this hardware/traffic profile).
- [x] Verified after the switch: recreating the crowdsec container again produced a brief window where `crowdsec@docker` didn't resolve (Traefik logged `middleware "crowdsec@docker" does not exist`), but Traefik kept serving its last-known-good dynamic config throughout — no `403`s, no dropped requests, confirmed via access log status codes during the transition.
- [ ] Not done: no alerting on bouncer-deny spikes. Given `live` mode removes the actual failure mode that caused this, not pursued for now — revisit if `live` mode's own failure behavior (LAPI unreachable mid-request) ever needs the same scrutiny.

## Follow-up

Fix applied and verified 2026-08-10, same session. `apps/crowdsec/SETUP.md` and the design doc that led to this rollout already reflect `live` mode.
