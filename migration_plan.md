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

**Login worked, but with a new twist on the Vikunja account-linking
issue:** the `/init` onboarding wizard creates a local-credentials admin
account (in a seeded `credentials-admin` group) independently of OIDC
being configured at all - so even with `AUTH_PROVIDERS=oidc` only and
zero pre-existing "real" local accounts, the very act of completing
first-run setup created one. The subsequent OIDC login then created a
**second**, separate account (matched by `provider=oidc`, Homarr doesn't
auto-link to the credentials account by default) landing only in the
default `everyone` group - no admin rights. Homarr does ship a
group-sync mechanism (`AUTH_OIDC_GROUPS_ATTRIBUTE=groups` maps OIDC
`groups` claims to same-named local Homarr groups) and had a pre-seeded
`admin` group ready for exactly this - but LLDAP's group is named
`admins` (plural, matching every other app's convention in this repo),
so the name never matched and auto-sync silently did nothing.

Fixed directly in Homarr's sqlite DB
(`${STORAGE_ROOT}/bronze/homarr/db/db.sqlite`, `better-sqlite3`) after
confirming zero real data was tied to the orphaned account (board
`creator_id` was `NULL` - system-seeded, not personally owned): added
the OIDC account to the `admin`-permission group, renamed that group to
`admins` to match LLDAP going forward, and removed the now-permanently-
unusable local credentials account (local login is disabled, so it could
never be logged into again) along with its now-empty `credentials-admin`
group. **Gotcha inside the fix:** first attempt at the DB write silently
did nothing - forgot `docker run -i` (stdin attachment) with the sqlite3
container, so the heredoc SQL never reached the process at all, no error,
no effect. Container access needs `-i` when piping SQL via stdin.

**Worth checking for any future OIDC app with an unattended/init-wizard
first-run flow** (anything that seeds a local admin account on first
boot, independent of the auth-provider config) - the same
account-fragmentation pattern could recur.

## MinIO Console (added 2026-08-05)

Third Tier 2/OIDC app, and the first that already existed and was
running before this rollout (unlike Homarr) but had **never had an NPM
host at all** - reachable only via direct host ports (`9008` S3 API,
`9009` Console), no domain, no TLS. Console now goes through
Traefik/Authelia like everything else; **the S3 API stays exactly as it
was, untouched, still on its direct port** - deliberate, not an
oversight. Scripts/rclone/backup jobs use access-key auth, not a
browser, so OIDC doesn't apply there and putting it behind Authelia
would just break them. Removed the Console's port publish (`9009`) once
Traefik could reach it internally, same as every other app that had a
leftover direct port.

**Same group-name-matching gotcha as Homarr, caught this time before it
bit anyone:** MinIO maps the OIDC `groups` claim directly to **MinIO
policy names** for console permissions - it doesn't auto-provision
access, so an LLDAP group with no identically-named MinIO policy gets
nothing. Cloned the built-in `consoleAdmin` policy (`mc admin policy info
localadmin consoleAdmin`) into a new policy literally named `admins`
(`mc admin policy create localadmin admins <policy.json>`) to match
LLDAP's group name, mirroring the fix already made for Homarr. Deliberately
did **not** create a `users` policy - MinIO holds real data (`gold` tier
storage), so the `users` LLDAP group getting no console access at all by
default is the correct safe posture, not a gap to fill.

**Authelia-specific client settings** (from Authelia's own MinIO
integration notes, not the generic OIDC client template):
`access_token_signed_response_alg: 'none'` and
`userinfo_signed_response_alg: 'none'`, plus
`MINIO_IDENTITY_OPENID_CLAIM_USERINFO=on` on MinIO's side - Authelia's
docs flag MinIO as not fully honoring standard OIDC claim retrieval
(same underlying class of issue as Homarr's `FORCE_USERINFO`, different
client, same root cause).

**Gotcha, unrelated to OIDC:** the `mc alias` used to create the
`admins` policy is **not** persisted - it's local `mc` CLI config inside
the container, not part of MinIO's own data on the `${STORAGE_ROOT}/gold/minio`
volume. Recreating the container loses the alias (confirmed: had to
re-run `mc alias set` after the compose redeploy) but **not** the policy
itself, which lives in MinIO's own IAM data and does persist. Don't
mistake a missing alias for a lost policy.

**Not yet confirmed end-to-end** - same honest caveat as Homarr's first
pass: discovery/routing checks pass, container started cleanly with no
OIDC config errors in its logs, but the actual login (and specifically
whether the `admins` policy grants the expected console permissions) is
still Aaron's to confirm. New NPM host needed too - `minio.anarchy.pizza`
never existed as a proxy host before this, so it needs creating from
scratch (Forward Hostname/IP `traefik`, Port `8080`, request a cert,
Force SSL) rather than repointing an existing one.

## MinIO → RustFS migration (started 2026-08-05)

**Why:** while setting up MinIO Console's OIDC login, discovered the
button just wasn't there. Root cause wasn't a config mistake - MinIO
removed Console SSO from the open-source Community Edition entirely
around the May 2025 release, pushing users toward a new paid "AIStor"
product. Confirmed via GitHub issues #21324/#21325 and Aaron's own
priors (this was already on his radar as a thing to deal with). Checking
further: **MinIO's open-source repo was archived (read-only) in February
2026** after entering maintenance mode in December 2025 - it's not a
missing feature, the whole project is frozen upstream. This is a genuine
migration, not a workaround.

**Alternatives considered:**
- **SeaweedFS** (Apache 2.0, most production-proven) - ruled out. Same
  problem as MinIO: admin UI OIDC login is explicitly gated to
  "SeaweedFS Enterprise," not open source. Doesn't solve what we're
  trying to get away from.
- **Garage** (AGPL, built by Deuxfleurs, a non-profit collective - zero
  commercial-pivot risk) - solid and genuinely free, but ships **no
  official web console at all**, just CLI/API. OIDC-capable UIs exist
  (e.g. `garage-ui`) but are separate, less-established third-party
  projects, not an official all-in-one.
- **RustFS** (Apache 2.0, explicit MinIO drop-in, 30.7k stars and
  growing specifically because of the MinIO situation) - **chosen**.
  Ships its own console with genuinely open, non-gated OIDC support. The
  real tradeoff: pre-1.0 beta software. Found (and this mattered) a
  since-closed GitHub issue (#2924, filed May 2026) where RustFS's own
  S3 signature-validation middleware rejected OIDC callback redirects
  with `403 Signature is required` - a fundamental, not cosmetic, bug
  that would have blocked login entirely. Closed by August 2026 (this
  session), but which exact version includes the fix wasn't confirmed
  from documentation alone - **this needs actual testing, not just
  trusting the issue tracker**, before declaring OIDC login done.

**Migration approach - deliberately NOT using RustFS's own "binary
replacement" migration path.** RustFS's docs describe pointing it
directly at MinIO's existing on-disk data directory for automatic
migration, but explicitly warn "not all MinIO data can currently be
migrated automatically" (site replication, notifications, LDAP/OIDC
config excluded) and don't confirm single-node support. With 118GiB of
real data across 3 buckets - including what turned out to be Duplicati
Windows backup data (`aaron-windows-backups`) - this was too risky to
gamble on. Used a conservative S3-level `mc mirror` instead: genuine
object-by-object copy over the S3 API, protocol-level rather than
filesystem-format-level, run with both MinIO and RustFS live
simultaneously so nothing about the source data was touched during the
copy.

**RustFS deployment gotchas hit (worth knowing before deploying it
again):**
- **Container runs as UID/GID `10001:10001`** (user `rustfs`), not root
  and not a configurable `PUID`/`PGID` like the linuxserver-style images
  elsewhere in this repo. The bind-mounted `/data` directory needs
  `chown -R 10001:10001` on the host **before** first start, or it fails
  immediately with `[FATAL] Server runtime failed: Io error: Permission
  denied (os error 13)`.
- **`/logs` needs the same treatment, separately** - a known upstream bug
  (GitHub #2396 and others): the image's own internal `/logs` directory
  isn't correctly chowned for the non-root user on its own, so even
  after fixing `/data`, startup still failed with the identical
  permission-denied error until `/logs` was also bind-mounted to a
  host directory and pre-chowned to `10001:10001`. Community-documented
  workaround, not something obvious from the docs alone.
- **Console isn't served at the domain root** - `https://rustfs.${DOMAIN}/`
  returns a plain `403`; the actual console lives at
  `https://rustfs.${DOMAIN}/rustfs/console/`. No redirect from root.
  Worth bookmarking the full path.
- **Callback URL actually used includes a `/default` provider-id suffix**
  RustFS wasn't given an explicit provider name (no such env var was
  set), so it auto-assigns one - `default` - and bakes it into the
  redirect URI it sends: `.../rustfs/admin/v3/oidc/callback/default`.
  The first registered client omitted this suffix (following the
  simplified example in a GitHub issue rather than the more general docs
  page, which did mention a `<provider-id>` segment) and failed with
  `invalid_request: redirect_uri does not match`. Confirmed the exact
  value from Authelia's own error log rather than guessing again.
- **PKCE is mandatory** (S256), unlike every other OIDC client registered
  so far (`require_pkce: false` for Vikunja/Homarr/MinIO) -
  `require_pkce: true` and `pkce_challenge_method: 'S256'` set on the
  Authelia client.
- **`token_endpoint_auth_method: 'client_secret_post'`**, not
  `client_secret_basic` - RustFS's own Keycloak setup docs describe
  "client-secret authentication in the token request body," which is
  `client_secret_post` by definition. Since Authelia has no
  RustFS-specific integration page (too new a project), this was
  inferred carefully from RustFS's own docs rather than reused from
  Vikunja/Homarr/MinIO's settings - each of those needed a *different*
  auth method, so guessing one-size-fits-all would have repeated the
  exact mistake made with Vikunja earlier in this rollout.
- **Same group-name-to-policy mapping pattern as MinIO** - RustFS maps
  the OIDC `groups` claim to a RustFS policy name, no
  auto-provisioning. Created an `admins` policy (`admin:*` + `s3:*`)
  proactively via `mc admin policy create`, matching LLDAP's group name,
  *before* attempting any real login this time.
- **`mc` isn't bundled in the RustFS image** (unlike MinIO's image, which
  had it available for the healthcheck) - used a standalone
  `minio/mc` container on the `anarchy-pizza` network instead, with a
  bind-mounted config dir so aliases persist across separate `docker run`
  invocations.

**The data migration attempt surfaced a real reliability problem with
RustFS, not just a config issue - worth recording even though the
outcome changed.** Two `mc mirror` attempts against the live 118GiB
dataset both failed:
1. First attempt: aborted when MinIO itself (the source, not RustFS)
   returned `Service not ready: waiting for storage_quorum` - MinIO
   stayed up throughout (no restart), so this reads as transient I/O
   contention under heavy read load rather than an actual MinIO fault.
2. Second attempt: RustFS returned a truncated response mid-upload
   (`http: ContentLength=16777216 with Body length 5808320` - client
   declared 16MB, connection dropped after 5.8MB), **and RustFS itself
   restarted mid-transfer** - clean exit code, `OOMKilled: false`, no
   panic trace in the logs, just a silent restart. After that restart,
   RustFS held only 487MiB/20 objects, far less than what `mc` had
   already reported as successfully transferred. Data reported as
   "transferred" did not durably survive the restart.

That's a genuine data-durability gap under sustained bulk-write load,
not a checkbox to enable or an auth-method mismatch like every other
gotcha this session - a materially more serious class of problem than
"the SSO button doesn't work," since it's the storage engine itself, not
a login flow.

**Resolution: turned out not to matter.** Asked Aaron directly rather
than keep retrying against real data - the 118GiB in MinIO (mostly
Duplicati Windows backup data) **wasn't actually needed anymore**. That
changed the entire calculus: no data to lose, so the crash became a data
point about RustFS's maturity rather than a live incident. Confirmed
RustFS was still stable 51 minutes after the crash (no further
restarts), ran a small light write/read/delete test (150MiB across 3
files) to confirm basic reliability before trusting it with anything,
and it passed cleanly. **Do not assume this same crash pattern is
resolved or won't recur under real sustained load** - it was never
root-caused, just sidestepped because the stakes changed. Worth
retesting properly (large sustained transfer, watching for the same
restart) before ever putting real precious data on this RustFS instance.

**MinIO decommissioned:** containers stopped, `apps/minio` moved to
`archived/minio`, its OIDC client removed from `identity_providers.yml`.
Its 118GiB of data was deliberately **not** deleted, left intact at
`${STORAGE_ROOT}/gold/minio` in case it's ever wanted back (same as
every other archived app in this repo) - just unused, not destroyed.

## RustFS OIDC debugging - four real bugs found, one unresolved, RustFS abandoned (2026-08-05)

Pushed hard on getting RustFS's console OIDC actually working (not just
config-that-looks-right, per the standing lesson from Vikunja) rather
than stopping at the consent-redirect check. Along the way, built real
tooling to verify this properly: completed a **full manual OIDC flow via
curl** (login → authorization → GET `/api/oidc/consent?flow_id=` →
POST the consent decision → follow the final redirect for a real
authorization code → exchange it at `/api/oidc/token` with a genuine
PKCE verifier) to inspect actual tokens rather than guessing - useful
technique, worth reusing for Vaultwarden or any future OIDC app instead
of stopping at "consent redirect returned so it's probably fine."

**Bug 1 - wrong redirect URI.** Registered
`.../oidc/callback` without a provider-id suffix, following a
simplified GitHub issue example rather than the fuller docs. RustFS
actually sends `.../oidc/callback/default` (it auto-assigns `default`
as the provider id since none was explicitly configured). Confirmed the
real value from Authelia's own rejection log rather than guessing again
- **fixed**.

**Bug 2 - client secret silently out of sync.** At some point during
setup, the plaintext secret written to `apps/rustfs/.env` stopped
matching the PBKDF2 hash stored in `identity_providers.yml` - never
root-caused exactly where the drift happened, but caught it by manually
completing the token exchange and getting `invalid_client`, then using
`authelia crypto hash validate` to directly confirm the mismatch rather
than assuming. Refixed carefully: generated a hex-only secret (no
`+`/`=`/`/` characters, to eliminate any shell/YAML escaping as a
variable), validated match at every single step before writing either
file, confirmed byte-for-byte before deploying - **fixed, verified**.

**Bug 3 - ID token had no `groups` claim at all.** Authelia 4.39+ stopped
including claims in ID tokens by default (a real, documented behavior
change) - `groups` was only ever in the `userinfo` response, and
RustFS's OIDC handler (confirmed by reading its actual source on
GitHub, `rustfs/src/admin/handlers/oidc.rs`) only processes the code
exchange result, never calls `userinfo`. Fixed with an explicit
`identity_providers.oidc.claims_policies` block naming which claims
(`groups`, `email`, `preferred_username`, `name`) belong in the ID
token, referenced from the client via `claims_policy: 'rustfs'`.
Verified directly via the manual-flow tooling above: the ID token
genuinely contained `"groups": ["admins", "lldap_admin"]` afterward -
**fixed, verified**.

**Bug 4 - policy mapping still never resolved, unresolved.** Even with a
confirmed-correct `groups` claim reaching RustFS, `OIDC policy mapping
did not resolve to current policies` persisted through three different
claim-config permutations (`groups_claim` alone; adding `roles_claim`
pointed at the same data; adding `claim_name` too - all three
documented-but-differently-named RustFS settings for this). No richer
detail available in RustFS's own debug-level logs beyond the generic
error. This is very likely the same class of issue as a related open
RustFS GitHub bug found earlier (#2612, OIDC + `consoleAdmin` policy
behaving incorrectly) - a genuine gap in RustFS's beta policy-resolution
code, not a configuration mistake on our end. **Not fixed, not
root-caused** - stopped here rather than keep guessing at more
undocumented env vars.

**Decision: abandoned RustFS entirely**, not just the OIDC piece. Between
this and the earlier untraced data-corruption-on-crash finding (see
above), two independent, serious reliability problems surfaced in the
time it took to attempt one integration - enough of a pattern to
disqualify the beta software itself, not just work around one bug.
`apps/rustfs` moved to `archived/rustfs`, its OIDC client and
`claims_policies` block removed from `identity_providers.yml` and
verified clean (`['vikunja', 'homarr']` only). Its data directories
(`${STORAGE_ROOT}/gold/rustfs`, `${STORAGE_ROOT}/gold/rustfs-logs`) left
on disk, untouched - never held anything but a throwaway sanity-test
bucket, already cleaned up before archival.

**Where this leaves S3-compatible storage: unresolved, deliberately
deferred.** No object storage app is currently running in this stack.
Earlier evaluation (SeaweedFS: mature but Console OIDC is Enterprise-
gated; Garage: genuinely free, no official console, needs a third-party
UI) still stands - see "MinIO → RustFS migration" above for that
comparison. Worth revisiting with a bias toward **proven stability over
native OIDC support** given how this round went - an Authelia
forward-auth wrapper (the Dozzle/Uptime Kuma pattern) around a mature
app's own login, regardless of whether that app has any SSO of its own,
sidesteps this entire bug class and has worked cleanly every single time
it's been used this session. Picking back up here was interrupted mid-
discussion, not concluded - no next step has been decided yet.

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
  previously in the repo. Second Tier 2/OIDC app, **fully working**,
  confirmed by Aaron logging in for real. Local credentials login
  subsequently disabled (`AUTH_PROVIDERS=oidc` only, `AUTH_OIDC_AUTO_LOGIN=true`
  so the single remaining method skips a pointless chooser screen) - see
  "Homarr" above for the full setup, the Vikunja lessons applied up
  front, and the admin-group account-fragmentation issue hit and fixed
  after switching to OIDC-only.
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
- MinIO — retired with no replacement currently running (see "MinIO →
  RustFS migration" above). Containers stopped/removed, `apps/minio`
  moved to `archived/minio`, its OIDC client removed from
  `identity_providers.yml`. The 118GiB of data that had been in it
  (Duplicati Windows backups, mostly) was confirmed by Aaron as no
  longer needed and was **not** migrated anywhere - left intact,
  untouched, at `${STORAGE_ROOT}/gold/minio` in case it's ever wanted
  back, same treatment as every other archived app's data.
- RustFS — abandoned during setup itself, never reached production use
  (see "RustFS OIDC debugging" above for the full story: four real bugs
  found and fixed getting OIDC working, a fifth that beat us, plus an
  earlier untraced data-durability crash during the (ultimately
  unneeded) data migration attempt). `apps/rustfs` moved to
  `archived/rustfs`. Data directories
  (`${STORAGE_ROOT}/gold/rustfs`, `${STORAGE_ROOT}/gold/rustfs-logs`)
  left on disk, untouched - never held anything but an already-cleaned-up
  sanity-test bucket. **No S3-compatible storage is currently running in
  this stack** - deliberately deferred, not yet decided.

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
- **Minio/S3-compatible storage** — unresolved, not currently running.
  MinIO's open-source Console SSO was removed upstream (and the whole
  project archived), so it was replaced with RustFS - which was then
  itself abandoned after real, unresolved OIDC and reliability problems
  (see "MinIO → RustFS migration" and "RustFS OIDC debugging" above).
  No object storage app is live in this stack right now. Next attempt
  should bias toward proven-stable options (SeaweedFS, Garage) wrapped
  in Authelia forward-auth rather than chasing another app's native
  OIDC maturity.
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

## Stray finding: Vaultwarden healthcheck (fixed 2026-08-05)

Unrelated to the SSO rollout, found during a post-migration audit -
Vaultwarden showed `unhealthy` in `docker ps` despite working fine
(`vault.anarchy.pizza` returned `200`). Cause: `apps/vaultwarden`'s
healthcheck hit `http://localhost:80/health`, which 404'd; the actual
endpoint on the current image (`vaultwarden/server:latest`, a floating
tag) is `/alive`. The endpoint apparently moved upstream at some point
and the healthcheck definition was never updated to match. Fixed by
changing the healthcheck path; confirmed `healthy` afterward. Also
caught along the way: redeploying without Vaultwarden's own local `.env`
(only the root one) silently drops `VAULTWARDEN_DOMAIN` - both
`--env-file` flags matter, same as every other app in this repo.

## Suggested next step

**S3-compatible storage is an open decision, not started.** RustFS was
abandoned (see "RustFS OIDC debugging" above) — no object storage app is
currently running. When picked back up, bias toward proven stability
over native OIDC support: SeaweedFS or Garage, wrapped in Authelia
forward-auth (the Dozzle/Uptime Kuma pattern) rather than depending on
either project's own SSO maturity. This was mid-discussion when the
session moved on, not a settled decision.

Separately, Vaultwarden is the last standing Tier 2 candidate from the
original plan — its OIDC flows through the real Bitwarden-compatible
clients, not just the web vault, a genuinely different integration
surface than everything done so far, worth extra care testing an actual
client app, not just the browser. Also worth a pass checking every live
OIDC app (Vikunja, Homarr) for the two recurring gotcha classes hit this
round: leftover local/pre-existing accounts not linked to the SSO
identity, and OIDC group claims not matching the target app's expected
group/policy/role name.
