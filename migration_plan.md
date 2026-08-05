# Traefik + Authelia Migration Notes

Started 2026-08-04. Goal: move apps off direct NPM→container proxying onto
NPM → Traefik → app, with Authelia providing SSO/forward-auth in front of
apps that want it — without tearing down NPM or causing downtime for
untouched apps.

## Architecture

- **NPM** stays the public edge: holds ports 80/443/81, terminates TLS,
  issues Let's Encrypt certs. Unchanged for apps not yet migrated.
- **Traefik** (`apps/traefik`) runs on the internal `anarchy-pizza` docker
  network only — publishes no host ports, so it can't collide with NPM.
  Listens on `:8080` (entrypoint `web`). Routes by Host header via Docker
  labels (`providers.docker`, `exposedByDefault=false`, so only explicitly
  labeled containers get routed).
- **Authelia** (`apps/authelia`) is the forward-auth SSO layer. Portal at
  `auth.${DOMAIN}`. Traefik's `authelia@docker` middleware calls its
  `/api/verify` endpoint; unauthenticated requests get a 302 to the portal.
- Per-app migration = flip that app's existing NPM proxy host to forward to
  `traefik:8080` instead of the app container directly. Traefik then does
  the actual host-based routing to the real container internally.

`DOMAIN=anarchy.pizza` lives in the root `.env` (added this migration,
`.env.example` updated too) — used in all `Host()` label rules.

## Per-app migration checklist

1. Add Traefik labels to the app's `docker-compose.yml`:
   ```yaml
   labels:
     - traefik.enable=true
     - traefik.http.routers.<name>.rule=Host(`<sub>.${DOMAIN}`)
     - traefik.http.routers.<name>.entrypoints=web
     - traefik.http.services.<name>.loadbalancer.server.port=<container_port>
   ```
   Add `- traefik.http.routers.<name>.middlewares=authelia@docker` too if
   it's getting Authelia-protected.
2. If Authelia-protected, add an `access_control` rule for the domain in
   `apps/authelia/configuration.yml`, then `docker restart authelia`
   (compose won't pick up bind-mounted config changes on its own — the
   container has to be explicitly restarted).
3. Redeploy the app: `docker compose --env-file ../../.env up -d`.
4. Sanity-check before touching NPM — exec into NPM and hit Traefik
   directly with headers that simulate what NPM will send:
   ```
   docker exec npm curl -s -D - -o /dev/null \
     -H "Host: <sub>.anarchy.pizza" -H "Accept: text/html" \
     -H "X-Forwarded-Proto: https" -H "X-Forwarded-Host: <sub>.anarchy.pizza" \
     -H "X-Forwarded-Uri: /" http://traefik:8080
   ```
   Expect a 302 to `auth.anarchy.pizza` (if Authelia-protected) or a 200
   from the app (if not).
5. **Manual, in NPM UI** (not git-managed, lives in NPM's sqlite db):
   edit/create the proxy host → Forward Hostname/IP `traefik`, Forward Port
   `8080` → SSL tab → request a new Let's Encrypt cert → enable **Force
   SSL**. Authelia flatly refuses to issue session cookies over plain HTTP,
   so skipping Force SSL here produces a confusing 401 instead of a login
   redirect (this is exactly what happened on Dozzle's first pass — its
   host had never had a cert issued at all).
6. Verify live from outside: `curl -v https://<sub>.anarchy.pizza` — check
   cert CN and the redirect Location header.

## Gotchas hit during this migration (don't re-debug these)

- **`traefik:v3.1` couldn't talk to the Docker daemon** — host is Docker
  Engine 29.1.3 (API 1.52), and that Traefik version's bundled client
  capped out negotiating at API 1.24. Fixed by bumping to `traefik:latest`
  (currently resolves to v3.7.10). Worth pinning to a specific tag once
  this settles rather than floating on `latest` long-term.
- **Traefik wasn't trusting NPM's `X-Forwarded-Proto`**, so Authelia saw
  every request as `http://...` and refused to issue secure cookies, even
  over a real HTTPS connection. Fixed with
  `--entrypoints.web.forwardedHeaders.trustedIPs=172.25.0.0/16` (the
  `anarchy-pizza` network subnet) in `apps/traefik/docker-compose.yml`.
- **Authelia config is bind-mounted, not baked into the image** — editing
  `apps/authelia/configuration.yml` and running `docker compose up -d`
  does nothing until you `docker restart authelia`.
- Authelia's own secrets (`session_secret`, `storage_encryption_key`,
  `jwt_secret`, `ldap_bind_password`) live on the host at
  `${STORAGE_ROOT}/silver/authelia/secrets/` — deliberately **not** in the
  repo, unlike `configuration.yml` which has no secrets in it and is
  tracked. The old file-based `users_database.yml` is gone (see LLDAP
  section below).
- Authelia's session provider has no Redis configured — sessions are
  in-memory only, so **every Authelia restart logs everyone out**. Fine at
  current scale; revisit if that gets annoying.
- Certs are per-app (HTTP-01), not a wildcard. Confirmed with Aaron this is
  fine for now — can switch to a wildcard `*.anarchy.pizza` cert (DNS-01,
  needs a DNS provider API token) later if the per-app cert dance gets
  old across the whole stack.

## Identity backend: LLDAP (added 2026-08-05)

Authelia's authentication backend was switched from a flat file
(`users_database.yml`) to **LLDAP** (`apps/lldap`), a lightweight LDAP
server with its own web UI, so users/groups/passwords are managed properly
instead of hand-editing YAML and re-hashing passwords on every change.

**Why internal-only:** LLDAP's web UI is bound to this host's Tailscale
interface only (`${TAILSCALE_IP}:17170`, see `apps/lldap/.env`) — no
NPM/Traefik route, no public domain, not reachable from the plain LAN or
internet. Reasoning: Authelia authenticates against LLDAP, so if LLDAP's
own admin UI were put behind Authelia's forward-auth, a broken LDAP
connection would lock out the one tool needed to fix it (circular
dependency). Reach the UI at `http://100.118.184.115:17170` from any
device on the tailnet — no SSH tunnel needed. (Docker's embedded DNS lets
containers reach `lldap:3890`/`lldap:17170` by name already — that's
container-to-container only and doesn't help an external device like a
laptop, which is why the host port publish onto the Tailscale interface is
what actually makes the UI browsable.) Traffic between `authelia` and `lldap` is plain
`ldap://` (no TLS) — deliberate, since it never leaves the `anarchy-pizza`
docker bridge network and NPM is the only TLS-terminating point in the
whole stack (same reasoning as Traefik's internal `:8080` entrypoint).

**Bootstrapping (declarative, no manual UI clicking):** LLDAP ships
`/app/bootstrap.sh` baked into the image. It reads JSON files under a
mounted `/bootstrap` directory and reconciles LLDAP's users/groups to match
— run it any time with `docker exec lldap /app/bootstrap.sh` after editing
a config file. Real config (including plaintext passwords used only to
set/reset an account's password via the API — LLDAP hashes them, this
repo never stores the plaintext) lives host-only at
`${STORAGE_ROOT}/silver/lldap/bootstrap/{user-configs,group-configs}/*.json`
— **not in git**, same treatment as `users_database.yml` used to get.

**Roles:** two custom groups, `admins` and `users` (distinct from LLDAP's
own built-in `lldap_admin`/`lldap_strict_readonly` groups, which control
who can administer LLDAP itself, not app access).
- `aaron` → `admins` (+ `lldap_admin`, so Aaron can also manage LLDAP
  itself through its real UI instead of only the break-glass `admin`
  account).
- `testuser` → `users` — a throwaway account for verifying role
  restrictions actually apply.
- `authelia` → `lldap_strict_readonly` — the service account Authelia
  binds as to query LLDAP; read-only, can't administer anything.

**Access control** (`apps/authelia/configuration.yml`) is now
group-based instead of domain-only: `admins` get `one_factor` on
`*.anarchy.pizza` (everything); `users` are explicitly denied on
`dozzle.anarchy.pizza` and `uptime.anarchy.pizza` (checked before the
wildcard admin/user allow rules, since Authelia takes the first matching
rule top-to-bottom) and otherwise get `one_factor` on anything else added
later. Verified directly against Authelia's API (`/api/firstfactor` then
`/api/verify` with the resulting session cookie) rather than just eyeballing
the config: `aaron` → `200` on dozzle, `testuser` → `403` on both dozzle and
uptime.

**Gotcha:** LLDAP will reject creating a user if its email collides with
an existing one (`UNIQUE constraint failed: users.lowercase_email`) —
bit us because the break-glass `LLDAP_LDAP_USER_EMAIL` was initially set to
Aaron's real email, colliding with the `aaron` LDAP user bootstrap tried to
create. Fixed by giving the break-glass admin a distinct internal address
(`admin@anarchy.pizza`) — it's a separate identity from any personal
account, not meant to represent a real person.

## Status as of 2026-08-05

**Live behind Traefik + Authelia, LDAP-backed, role-restricted:**
- `dozzle.anarchy.pizza` — Dozzle has no auth of its own, Authelia is the
  only gate. `admins` group only.
- `uptime.anarchy.pizza` — Uptime Kuma has no OIDC/header-auth support, so
  its own login was disabled (Settings → Security → Disable Auth, confirmed
  `disableAuth=true` in its `kuma.db`) so Authelia is the sole gate.
  `admins` group only.
- `news.anarchy.pizza` — FreshRSS (`apps/freshrss`), replacing CommaFeed.
  Real single-login SSO, not just a gate: FreshRSS's `auth_type=http_auth`
  trusts the `Remote-User` header Authelia's forward-auth middleware
  already sends, so logging into Authelia logs you straight into FreshRSS
  as the matching local account (`aaron`) — no second login screen.
  `TRUSTED_PROXY=172.25.0.0/16` (the `anarchy-pizza` subnet) tells
  FreshRSS to trust that header only when it arrives from inside the
  Docker network. SQLite backend (simpler than CommaFeed's separate
  Postgres container — no real need for it at this scale). Verified past
  just config-reading: curled through Traefik with a real Authelia session
  cookie and confirmed a `200` landing directly in the reader UI (title
  showed the unread count), not a login form. Account created via
  `FRESHRSS_INSTALL`/`FRESHRSS_USER` env vars on first run (unattended
  install, see `apps/freshrss/docker-compose.yml`) — those env vars are
  **only read on first run**; changing them later requires deleting the
  `freshrss` container and `${STORAGE_ROOT}/silver/freshrss/data` volume
  and reinstalling. OPML import left to Aaron via the GUI.
- `auth.anarchy.pizza` — Authelia's own portal.
- LLDAP (`apps/lldap`) — internal-only, bound to this host's Tailscale
  interface; see "Identity backend: LLDAP" above.

**Decommissioned:**
- Portainer — torn down per Aaron's call (not migrated). Containers
  stopped/removed, `apps/portainer` moved to `archived/portainer`
  (`git mv`'d, staged — not committed yet as of this note). Data left
  intact at `${STORAGE_ROOT}/bronze/portainer` in case it's ever wanted
  back. Never had an NPM host, so no NPM cleanup was needed either.
- CommaFeed — replaced by FreshRSS (see above). Containers stopped/removed,
  `apps/commafeed` moved to `archived/commafeed` (`git mv`'d, staged — not
  committed yet). Postgres data left intact at
  `${STORAGE_ROOT}/silver/commafeed-postgresql` in case it's ever wanted
  back.

**Cleanup TODO:**
- Stray leftover NPM proxy host with a typo —
  `server_name uptime.anarchy.pizz;` (missing the final "a"), HTTP-only, no
  SSL. Harmless (nothing resolves to it) but should be deleted in the NPM UI.
- `news.anarchy.pizza`'s NPM proxy host still points its Forward
  Hostname/IP at `commafeed:8082`, which no longer exists. **Manual step
  needed:** in the NPM UI, edit that host → change Forward Hostname/IP to
  `traefik`, Forward Port to `8080` (SSL/Force SSL already configured on
  that host from the CommaFeed days, no cert changes needed).

## Candidate apps for Authelia — ranked

The key question per app: does it have its own login, and if so, can that
be reconciled with Authelia so you don't get a double-login (Authelia's
portal, then the app's own separate login right after)?

### Tier 1 — no native auth, Authelia is the only gate needed (pattern proven)
- **Dozzle** — done.
- **Uptime Kuma** — done (own login disabled).

### Tier 1b — header-based reverse-proxy auth, real single-login SSO (pattern proven)
- **FreshRSS** — done, replaced CommaFeed. `auth_type=http_auth` +
  `trusted_sources`/`TRUSTED_PROXY` trusts Authelia's `Remote-User` header
  directly — logging into Authelia logs you into the app itself, no
  second login. Same underlying mechanism as Tier 3 below (Calibre-web),
  just supported natively instead of via a bolt-on option.

### Tier 2 — has native OIDC support, real one-login SSO possible
These need Authelia configured as an actual **OIDC provider** (not just
forward-auth) — a bigger one-time step (`identity_providers.oidc` block in
`configuration.yml`, per-app client registration) that hasn't been done
yet. Forward-auth alone won't give SSO for these; it would just add a
second, redundant gate in front of their own login.
- **Vikunja** — solid native OIDC support, can even force OIDC-only login
  and drop local accounts entirely.
- **Minio** (Console only) — OIDC via `AssumeRoleWithWebIdentity`. Do
  **not** put the S3 API endpoint behind Authelia/OIDC — scripts/rclone/etc.
  use access keys, not browser auth, and would break.
- **Vaultwarden** — upstream added native OIDC/SSO that actually flows
  through the real Bitwarden-compatible clients (not just the web vault).
  This is Vaultwarden doing its own OIDC handshake against Authelia as
  IdP — a different mechanism from Traefik forward-auth, and a separate
  integration effort. Worth it eventually; softens the earlier concern
  about official clients bypassing browser login.

### Tier 3 — has header-based reverse-proxy auth support
- **Calibre-web** — has a real "Allow Reverse Proxy Authentication" option
  that trusts a header (Authelia already sends `Remote-User` etc. via
  `authResponseHeaders` on the middleware). Catch: the username must
  **already exist** in Calibre-web's own user DB — no auto-provisioning,
  so create the account once first, then point it at the `Remote-User`
  header. Also: Calibre-web must not be reachable except through the
  proxy, or anyone hitting it directly could spoof the header.

### Tier 4 — no viable SSO path found
- ~~**CommaFeed**~~ — resolved by replacing it with FreshRSS (Tier 1b
  above) rather than finding an SSO path for CommaFeed itself; it had
  none (checked its GitHub repo, issues, and docs directly — no
  header-auth, no OIDC).

## Suggested next step

Calibre-web is the natural next pilot — same header-auth pattern as
FreshRSS, just needs the one-time "create the account, flip on header
trust" step on the app side. Vikunja/Minio/Vaultwarden OIDC is a
separate, bigger effort (Authelia-as-IdP setup) worth doing as its own
session rather than folding into the forward-auth rollout.
