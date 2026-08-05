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
2. **Remove the app's `ports:` block if it has one.** Apps that pre-date
   the Traefik migration usually still have a host port published from
   the old direct-NPM-to-container setup - Traefik reaches every app over
   the internal `anarchy-pizza` network by container name, so once it's
   Traefik-routed the host port isn't needed and just gives a way to
   bypass Authelia entirely by hitting `host:<port>` directly. Bit us on
   Dozzle, Uptime Kuma, and Calibre-web - see "Security finding" below.
   Confirm with `curl http://localhost:<port>` after redeploying;
   connection-refused is what you want.
3. If Authelia-protected, add an `access_control` rule for the domain in
   `apps/authelia/configuration.yml`, then `docker restart authelia`
   (compose won't pick up bind-mounted config changes on its own — the
   container has to be explicitly restarted).
4. Redeploy the app: `docker compose --env-file ../../.env up -d`.
5. Sanity-check before touching NPM — exec into NPM and hit Traefik
   directly with headers that simulate what NPM will send:
   ```
   docker exec npm curl -s -D - -o /dev/null \
     -H "Host: <sub>.anarchy.pizza" -H "Accept: text/html" \
     -H "X-Forwarded-Proto: https" -H "X-Forwarded-Host: <sub>.anarchy.pizza" \
     -H "X-Forwarded-Uri: /" http://traefik:8080
   ```
   Expect a 302 to `auth.anarchy.pizza` (if Authelia-protected) or a 200
   from the app (if not).
6. **Manual, in NPM UI** (not git-managed, lives in NPM's sqlite db):
   edit/create the proxy host → Forward Hostname/IP `traefik`, Forward Port
   `8080` → SSL tab → request a new Let's Encrypt cert → enable **Force
   SSL**. Authelia flatly refuses to issue session cookies over plain HTTP,
   so skipping Force SSL here produces a confusing 401 instead of a login
   redirect (this is exactly what happened on Dozzle's first pass — its
   host had never had a cert issued at all).
7. Verify live from outside: `curl -v https://<sub>.anarchy.pizza` — check
   cert CN and the redirect Location header.

## Gotchas hit during this migration (don't re-debug these)

- **Always double-check Force SSL got enabled on a freshly-repointed NPM
  host**, not just that the cert exists. Every prior app in this rollout
  happened to get browsed over HTTPS regardless (typed with `https://`,
  or HSTS remembered from an earlier visit), masking that Force SSL
  wasn't actually on. Vikunja's SPA frontend calls its API via a
  hardcoded HTTPS `VIKUNJA_SERVICE_PUBLICURL` regardless of what scheme
  the page itself loaded under - so the one time a host got visited over
  plain `http://` first, it broke as a same-hostname-different-origin
  CORS error, not an obviously-SSL-shaped symptom. Any app whose frontend
  hardcodes an absolute HTTPS URL for its own API (SPAs are the likely
  culprits) is exposed to this if Force SSL is missing.
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

## Authelia as an OIDC provider (added 2026-08-05)

Tier 2 apps (Vikunja, eventually Minio/Vaultwarden) need Authelia
configured as an actual **OIDC provider**, not just forward-auth - a
bigger, one-time step under `identity_providers.oidc`.

**Two new secrets, neither with a reliable simple fix:**
- `hmac_secret` - random 64+ char string.
- `jwks` - an RSA private key (generated 4096-bit here; 2048 is the
  documented minimum), PEM format, needed to sign issued JWTs.

**How the secrets are kept out of git - and what didn't work first:**
Authelia's docs show a `{{ secret "/path" }}` templating mechanism for
exactly this (`AUTHELIA_CONFIGURATION_FILTERS=template` env var), with a
`mindent`/`msquote` filter combo specifically for multi-line PEM content.
Tried it first since it's the documented approach - it didn't work on
this Authelia version (`v4.39.20`): `AUTHELIA_CONFIGURATION_FILTERS` came
back as "not expected", meaning the filter was never actually active, so
the raw `{{ ... }}` template syntax got parsed literally as YAML and
failed (`invalid map key`), cascading into a wall of unrelated "required"
errors that made the real problem non-obvious at first glance.

Abandoned templating for something simpler and more robust: Authelia's
`--config` flag accepts multiple comma-separated files that get deep
merged (`authelia --config /a.yml,/b.yml`). Split `identity_providers.oidc`
(hmac_secret, jwks key, and the Vikunja client registration) into a
second file, `identity_providers.yml`, living host-only at
`${STORAGE_ROOT}/silver/authelia/` - same treatment the old
`users_database.yml` got, never in git. `apps/authelia/docker-compose.yml`
now sets `command: [--config, /config/configuration.yml,/config/identity_providers.yml]`
to load both.

**Gotcha inside that fix:** the command has to be the *space-separated*
form (`--config`, then the value, as two separate list items), not
`--config=value`. The image's `entrypoint.sh` special-cases a first
argument of exactly `--config` to prepend the `authelia` binary correctly;
anything else (including `--config=...` as one token) falls through to a
branch that tries to `exec` the literal string as a program name -
`illegal option --` was the resulting error, several layers removed from
the actual cause.

**Vikunja-side gotcha avoided:** Vikunja's OpenID config used to require
at least a minimal `config.yml` stub declaring the provider key before
env vars would be read for it - fixed upstream in Vikunja as of January
2025. The image in use here (`vikunja/vikunja:latest`) postdates that
fix, so the whole client config is env-var-only
(`VIKUNJA_AUTH_OPENID_PROVIDERS_AUTHELIA_*` in `apps/vikunja/.env`), no
config file needed.

**Client secret handling:** Authelia stores only a PBKDF2 hash of
Vikunja's client secret (`authelia crypto hash generate pbkdf2 --password
'...'`) - safe to commit in principle (one-way hash, this is literally
what Authelia's own docs show inline), but kept in the host-only
`identity_providers.yml` anyway for consistency with everything else in
this section. Vikunja gets the plaintext via its own `.env`.

**No forward-auth middleware on Vikunja's Traefik labels** - unlike every
Tier 1/1b/3 app, Vikunja talks to Authelia directly via OAuth redirects,
so stacking `authelia@docker` forward-auth on top would just add a
redundant, conflicting second gate.

**Verification:** OIDC discovery document (`/.well-known/openid-configuration`)
returns the expected issuer/endpoints; Vikunja's own `/api/v1/info`
correctly lists the `authelia` provider with the right `auth_url` and
`client_id`; hitting Authelia's real authorization endpoint with a valid
Aaron session cookie returns a `302` to Authelia's consent page rather
than an error - confirms `client_id`/`redirect_uri`/`scope` all validate
against the registered client. Didn't script past the consent screen
itself (it's a JS-driven flow, not worth reverse-engineering via curl) -
turned out that gap mattered: the actual token exchange (past consent)
failed with `invalid_client` / `"the OAuth 2.0 client registration does
not allow this method"` - Vikunja's OAuth2 client sends its secret via
`client_secret_post` (in the POST body), but the client was registered
with `token_endpoint_auth_method: 'client_secret_basic'` (HTTP Basic
Auth header instead). **Lesson: the consent redirect only proves the
authorization request is well-formed, not that the full flow works** -
token exchange is a separate, later step with its own failure modes.
Fixed by changing `token_endpoint_auth_method` to `client_secret_post` in
`identity_providers.yml` and restarting Authelia (which, per the
no-Redis gotcha above, logged everyone out).

**Account linking gotcha:** once the token exchange worked, the first
real OIDC login **created a brand new Vikunja account**
(`seemingly-large-skylark`) instead of using Aaron's existing local
`aaron` account, which had real project/task data. Root cause was two
separate things stacked together: (1) Vikunja never auto-links an OIDC
login to a local account unless `emailfallback` and/or `usernamefallback`
are explicitly enabled - neither was set, so it defaulted to "always
create new"; (2) even with fallback enabled, the local account's email
(`aaronw@ikmail.com`) didn't match the email Authelia/LLDAP actually
sends (`acwilsoncs@gmail.com`), so email matching would've missed it
anyway. Fixed by updating the local account's email to match (direct SQL
- Vikunja's own change-email flow requires a confirmation email, and the
mailer here is disabled, so it would've gotten stuck pending forever),
deleting the empty auto-created account and its default "Inbox" project
(confirmed zero real data first - `SELECT count(*) FROM tasks ...`),
and adding `VIKUNJA_AUTH_OPENID_PROVIDERS_AUTHELIA_EMAILFALLBACK=true`.
Deliberately did **not** enable `usernamefallback` - Vikunja's own docs
flag it as letting the provider claim any local account by username, a
real hijacking risk; `emailfallback` alone is sufficient once the emails
actually match. **Worth checking this same email-mismatch risk before
any future OIDC rollout (Minio/Vaultwarden)** if those apps have
pre-existing local accounts with a different email than what
LDAP/Authelia presents.

## Homarr (added 2026-08-05)

New app - wasn't in the repo or running before this, unlike everything
else migrated so far. `apps/homarr`, `ghcr.io/homarr-labs/homarr:latest`,
data at `${STORAGE_ROOT}/bronze/homarr`, `docker.sock` mounted read-only
for its Docker integration widgets. Second Tier 2 (real OIDC) app, same
pattern as Vikunja - registered as a client in `identity_providers.yml`,
Traefik labels with no forward-auth middleware.

Applied lessons from Vikunja up front rather than re-learning them:
- **`BASE_URL` and `NEXTAUTH_URL` both set to `https://homarr.anarchy.pizza`**
  - Homarr is Next.js/NextAuth-based and without these it generates
  `localhost` as the OIDC callback origin (a known upstream issue).
- **`AUTH_OIDC_FORCE_USERINFO=true`** - called out specifically in
  Authelia's own Homarr integration notes: without it, Homarr "does not
  honor the expected process to retrieve the claims it needs."
- **`token_endpoint_auth_method: 'client_secret_basic'`** used per
  Authelia's Homarr-specific doc example (not the generic default) -
  this is exactly the setting that was wrong for Vikunja
  (`client_secret_post` there), so used the client-specific
  recommendation this time instead of assuming one setting fits all
  OIDC clients.
- **No pre-existing local Homarr account to worry about** - it's a brand
  new app, so the account-linking/email-mismatch problem that bit
  Vikunja structurally can't happen here; didn't need
  `AUTH_OIDC_ENABLE_DANGEROUS_CREDENTIALS_LINKING` (Homarr's equivalent
  of Vikunja's `emailfallback`, named "dangerous" by Homarr's own devs)
  at all.
- Scopes include `groups` (Vikunja's didn't need this) - Homarr maps
  OIDC groups to local Homarr groups for permissions; not configured
  further than the default `everyone` group here.

**Verification, and an honest caveat:** discovery document and Traefik
routing confirmed; hitting Authelia's authorization endpoint with a real
Aaron session cookie returns the same `302` to Authelia's consent page
that Vikunja's did - which, per the lesson above, only proves
`client_id`/`redirect_uri`/`scope` are structurally valid, **not** that
the token exchange past consent actually works. Didn't repeat the
Vikunja mistake of calling that "verified" - it isn't, until Aaron
actually logs in.

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
- `library.anarchy.pizza` — Calibre-web (`apps/calibre-web`). Real
  single-login SSO, same as FreshRSS: "Allow Reverse Proxy Authentication"
  + header name `Remote-User`, set under Admin → **Basic Configuration**
  (not "UI Configuration" — easy to land on the wrong admin sub-page,
  which is what happened here at first) → scroll past "Google Books API
  Key", it's right before the "Login type" dropdown. Verified
  end-to-end: curled through Traefik with a real Authelia session cookie,
  got a `200`, title `Calibre-Web | Books`, zero password fields on the
  page, `aaron`/`Logout` present in the body — landed straight in the
  library, not a login form.
- `llm.anarchy.pizza` — Open WebUI (`apps/webui`). **This app wasn't in
  the repo at all before this** — it had been deployed by hand at some
  point (image `ghcr.io/open-webui/open-webui:ollama`, GPU passthrough,
  bundled Ollama, data at `${STORAGE_ROOT}/silver/open-webui` and
  `${STORAGE_ROOT}/bronze/ollama`) and its compose directory was gone from
  disk with nothing ever committed to git. Reconstructed from the running
  container's actual config (`docker inspect`, diffed against the image's
  own baked-in env to isolate what was actually deploy-specific — turned
  out to be nothing beyond volumes/network/GPU). Best SSO fit of all four
  apps so far: native `WEBUI_AUTH_TRUSTED_EMAIL_HEADER` support that
  **auto-registers or logs in by email match**, no pre-existing account
  needed (unlike FreshRSS/Calibre-web's username-match requirement). Set
  to `Remote-Email` (+ `WEBUI_AUTH_TRUSTED_NAME_HEADER=Remote-Name`).
  Already had no host port published, so it was clean on the port-leak
  issue below from the start. Verified via the actual signin endpoint
  (`POST /api/v1/auths/signin` through Traefik with a real Authelia
  session cookie) rather than just the static shell, since it's a JS SPA
  and a plain `curl` of `/` can't show auth state — got back a real JWT
  `token` cookie and a body matching Aaron's **existing** account
  (`acwilsoncs@gmail.com`, role `admin`, same avatar), not a fresh
  auto-provisioned one.
- `vikunja.anarchy.pizza` — Vikunja (`apps/vikunja`). **Fully working
  end-to-end**, confirmed by Aaron logging in for real. First Tier 2 app:
  real OIDC, not forward-auth - see "Authelia as an OIDC provider" above
  for the full setup and the four gotchas hit along the way (templating
  didn't work, `--config` needs the space-separated form, Force SSL
  wasn't on, and the token-exchange auth method mismatch that also
  created a duplicate account before `emailfallback` + a matching email
  fixed it). Traefik labels added with **no** `authelia@docker`
  middleware (OIDC apps talk to Authelia directly). Local login left
  enabled alongside OIDC rather than forcing OIDC-only, so there's a
  fallback if the OIDC config ever breaks.
- `homarr.anarchy.pizza` — Homarr (`apps/homarr`), new app, not
  previously in the repo. Second Tier 2/OIDC app - see "Homarr" above for
  the full setup and the Vikunja lessons applied up front. **Not yet
  confirmed working end-to-end** - discovery/routing/client-registration
  checks pass, but per the Vikunja experience that doesn't guarantee the
  token exchange does; Aaron's actual login is still the real test.
- `auth.anarchy.pizza` — Authelia's own portal.
- LLDAP (`apps/lldap`) — internal-only, bound to this host's Tailscale
  interface; see "Identity backend: LLDAP" above.

**Decommissioned:**
- Portainer — torn down per Aaron's call (not migrated). Containers
  stopped/removed, `apps/portainer` moved to `archived/portainer`. Data
  left intact at `${STORAGE_ROOT}/bronze/portainer` in case it's ever
  wanted back. Never had an NPM host, so no NPM cleanup was needed either.
- CommaFeed — replaced by FreshRSS (see above). Containers stopped/removed,
  `apps/commafeed` moved to `archived/commafeed`. Postgres data left intact
  at `${STORAGE_ROOT}/silver/commafeed-postgresql` in case it's ever
  wanted back.

**Cleanup TODO:**
- ~~Stray leftover NPM proxy host with a typo~~ — resolved, Aaron deleted
  it (confirmed gone from
  `nginx/proxy_host/` on disk, no `27.conf` and nothing references
  `anarchy.pizz` anymore).
- ~~`news.anarchy.pizza`'s NPM proxy host repoint~~ — resolved, confirmed
  live (`302` redirect to Authelia instead of the earlier `502`).
- ~~`library.anarchy.pizza`'s NPM proxy host repoint~~ — resolved, Aaron
  updated it, confirmed live end-to-end (see Calibre-web entry above).
- `llm.anarchy.pizza`'s NPM proxy host still points its Forward
  Hostname/IP at `open-webui:8080` directly. **Manual step needed:** in
  the NPM UI, edit that host → change Forward Hostname/IP to `traefik`,
  Forward Port to `8080` (SSL already configured on that host, no cert
  changes needed).
- ~~`vikunja.anarchy.pizza`'s NPM proxy host repoint~~ — resolved, Aaron
  updated it to `traefik:8080`. Hit a new bug doing so: **Force SSL was
  never enabled on this host** (unlike e.g. `vault.anarchy.pizza`, which
  has the `include conf.d/include/force-ssl.conf` block — Vikunja's
  `24.conf` didn't). Plain `http://` requests passed straight through
  instead of redirecting to `https://`. Since Vikunja's frontend always
  calls its API via the hardcoded HTTPS `VIKUNJA_SERVICE_PUBLICURL`,
  loading the page over HTTP created a same-hostname-different-origin
  mismatch, which the browser correctly blocked as CORS ("Login with
  Authelia" just spun, no request ever left the page). Fixed by enabling
  Force SSL on the host in the NPM UI. Full login confirmed working by
  Aaron end-to-end (see Status above for the account-linking fix that
  came after).

## Security finding: leftover direct host ports bypassed Authelia entirely (fixed 2026-08-05)

Discovered while double-checking Calibre-web's header-auth trust model:
**Dozzle (`:8888`), Uptime Kuma (`:3001`), and Calibre-web (`:8083`) all
still had their pre-Traefik host ports published**, meaning anyone on the
LAN could reach them directly and skip Authelia completely:
- Dozzle has no auth of its own at all — full live container logs, no
  auth needed, not even header spoofing.
- Uptime Kuma's own login was deliberately disabled in favor of Authelia
  being the sole gate — direct port access meant the full dashboard with
  zero auth.
- Calibre-web's header-auth trust (`load_user_from_reverse_proxy_header`)
  does **no IP/proxy validation** — direct access meant anyone could
  `curl -H "Remote-User: aaron" host:8083` and log in as Aaron with zero
  credentials.

All three confirmed reachable (`curl http://localhost:<port>` returned
`200`/`302` with real content, not connection-refused) before the fix.
Fixed by removing the `ports:` block from all three compose files —
Traefik reaches every app over the internal `anarchy-pizza` docker
network by container name, no host port needed once an app is
Traefik-routed. Re-verified all three: direct port now connection-refused,
Traefik route still returns the expected `302` to Authelia.

**Root cause:** these three apps all pre-dated the Traefik migration and
had host ports published for the old direct-NPM-to-container setup. Adding
Traefik labels doesn't remove the old port publish automatically — that's
a separate, easy-to-forget step. **Any future app migrated from
direct-NPM to Traefik should have its `ports:` block explicitly checked
and removed as part of the migration**, not just have labels added on
top. Worth adding this as an explicit step in the per-app migration
checklist above.

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
- **Open WebUI** — done. Best of this batch: `WEBUI_AUTH_TRUSTED_EMAIL_HEADER`
  matches by email and auto-registers if no account exists, so there's no
  pre-provisioning step at all (unlike FreshRSS/Calibre-web's
  username-must-already-exist requirement). Also wasn't in the repo to
  begin with — see Status above for the reconstruction story.

### Tier 2 — has native OIDC support, real one-login SSO possible
These need Authelia configured as an actual **OIDC provider** (not just
forward-auth) — a bigger one-time step (`identity_providers.oidc`, now
live — see "Authelia as an OIDC provider" above), plus per-app client
registration. Forward-auth alone won't give SSO for these; it would just
add a second, redundant gate in front of their own login.
- **Vikunja** — done. Local login left enabled alongside OIDC rather than
  forced OIDC-only (a deliberate fallback choice, easy to revisit — set
  `VIKUNJA_AUTH_LOCAL_ENABLED=false` and drop local accounts if the OIDC
  path proves solid over time).
- **Homarr** — new app (wasn't running before), added directly with OIDC
  from the start rather than migrating existing local accounts, so none
  of Vikunja's account-linking issues apply. Pending Aaron's real login
  to confirm the token exchange actually works — see "Homarr" above.
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
- **Calibre-web** — done. Unlike FreshRSS, the "Allow Reverse Proxy
  Authentication" toggle and header name are UI-only settings (no env
  var/CLI equivalent) — Admin → **Basic Configuration** (not "UI
  Configuration"), scroll past "Google Books API Key", right before
  "Login type". Catch confirmed the hard way: Calibre-web's
  `load_user_from_reverse_proxy_header()` does **zero IP/proxy
  validation** — it trusts the header from anywhere, unlike FreshRSS's
  `TRUSTED_PROXY` check. The compose file still had `ports: 8083:8083`
  published from before the Traefik migration, which meant anyone on the
  LAN could `curl -H "Remote-User: aaron" host:8083` and log in as Aaron
  with zero credentials — a real hole, not a theoretical one. Fixed by
  removing the port publish entirely; Traefik reaches it over the
  internal docker network by container name, no host port needed.
  **Worth auditing every other header-auth app for the same leftover
  direct-port pattern** — this is exactly the kind of thing that's easy
  to miss when adding Traefik labels to an app that pre-dates the
  Traefik migration.

### Tier 4 — no viable SSO path found
- ~~**CommaFeed**~~ — resolved by replacing it with FreshRSS (Tier 1b
  above) rather than finding an SSO path for CommaFeed itself; it had
  none (checked its GitHub repo, issues, and docs directly — no
  header-auth, no OIDC).

## Suggested next step

Finish Vikunja's manual consent click-through and NPM repoint (see
Cleanup TODO above), then Minio and Vaultwarden are what's left —
Authelia's OIDC provider is already live, so it's "just" per-app client
registration + app-side config now, the same pattern as Vikunja, not the
bigger from-scratch OIDC setup this round required. Minio: Console only,
never the S3 API endpoint (scripts/rclone use access keys, not browser
auth). Vaultwarden: its OIDC flows through the real Bitwarden-compatible
clients, not just the web vault — a genuinely different integration
surface than Vikunja's browser-only login, worth extra care testing an
actual client app, not just the browser.
