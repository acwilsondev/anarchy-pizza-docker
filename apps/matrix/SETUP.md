# Matrix (Synapse) setup - private, non-federated

This app is deliberately *not* set up like the rest of this repo's apps
(copy `.env.example`, `up -d`, done). Synapse's config file has to be
generated first, then hand-edited, because:

- It has no env-var substitution, so secrets (DB password, registration
  secret, signing key) have to live in the file itself - which means that
  file must never be committed. (This repo already got burned by exactly
  that: `archived/matrix/homeserver.yaml` had a real DB password committed
  in plaintext until it was redacted after the fact. Don't repeat it -
  nothing this doc has you edit lives under git.)
- Disabling federation and closing registration both require config keys
  that aren't in Synapse's default generated file.

## 1. Generate the base config

```bash
cd apps/matrix
cp .env.example .env
# edit .env: set a real POSTGRES_PASSWORD (e.g. `openssl rand -base64 24`)

docker compose --env-file ../../.env --env-file .env run --rm synapse generate
```

This writes `homeserver.yaml`, a signing key, and a log config into
`${STORAGE_ROOT}/gold/synapse/` on the host (bind-mounted to `/data`).
None of this is in the git repo - it lives only on the host filesystem,
same as every other app's `${STORAGE_ROOT}/silver/*/secrets/`.

## 2. Edit the generated homeserver.yaml

Open `${STORAGE_ROOT}/gold/synapse/homeserver.yaml` on the host and apply
these changes:

**Disable federation completely** (both directions - this is the actual
point of this whole setup):

```yaml
listeners:
  - port: 8008
    tls: false
    type: http
    x_forwarded: true
    bind_addresses: ['0.0.0.0']
    resources:
      # "federation" removed from this list - no federation resource is
      # served at all, so inbound requests from other homeservers 404.
      - names: [client]
        compress: false

# Outbound federation (joins, invites, presence, etc. to any remote
# server) blocked - empty whitelist means no domain is trusted.
federation_domain_whitelist: []
# Belt-and-suspenders: stop Synapse from sending federation traffic at all.
send_federation: false

# Defense in depth - irrelevant once federation is off, but don't let the
# client API leak room-directory info to unauthenticated callers either.
allow_public_rooms_without_auth: false
allow_public_rooms_over_federation: false
```

There's also no `ports:` entry for 8448 (the federation port) anywhere in
`docker-compose.yml`, and no Traefik router for it - so even if you ever
re-add "federation" to the resources list above by mistake, nothing
outside the `anarchy-pizza` Docker network can reach it.

**Point at Postgres instead of the default sqlite**, using the same
credentials as `apps/matrix/.env`:

```yaml
database:
  name: psycopg2
  args:
    user: synapse
    password: <same value as POSTGRES_PASSWORD in apps/matrix/.env>
    database: synapse
    host: synapse-postgresql
    port: 5432
    cp_min: 5
    cp_max: 10
```

**Close registration, but allow admin-created accounts** (friends get
accounts you create for them, not a public signup form):

```yaml
enable_registration: false
registration_shared_secret: "<generate with: openssl rand -hex 32>"
```

## 3. Start it

```bash
docker compose --env-file ../../.env --env-file .env up -d
```

## 4. Create an account for each friend

```bash
docker exec -it synapse register_new_matrix_user -c /data/homeserver.yaml http://localhost:8008
```

Run once per person. It prompts for username/password and whether the
account is an admin (say no, except for yourself).

## 5. DNS + client

Point `matrix.${DOMAIN}` (A/AAAA) at the server, same as every other
Traefik-routed app. Friends can then log into any Matrix client (Element,
etc.) with homeserver URL `https://matrix.${DOMAIN}`, or just use Element
Web at `https://chat.${DOMAIN}` (see `apps/element-web/`).

## 6. (Optional) SSO via Authelia

Same "Native OIDC" pattern Vikunja/Homarr use (see main README) - Synapse
talks to Authelia's OIDC endpoints directly, no Traefik forward-auth
middleware needed. `access_control`'s existing `*.anarchy.pizza` wildcard
rule already covers `matrix.${DOMAIN}`, so nothing to change there.

**Register the client in Authelia** - append to the `clients:` list in
`${STORAGE_ROOT}/silver/authelia/identity_providers.yml` (host-only, not
in git, deep-merged into Authelia's config - see
`apps/authelia/docker-compose.yml`):

```yaml
- client_id: 'matrix'
  client_name: 'Matrix'
  client_secret: '<pbkdf2 hash - see below>'
  public: false
  authorization_policy: 'one_factor'
  require_pkce: false
  redirect_uris:
    - 'https://matrix.${DOMAIN}/_synapse/client/oidc/callback'
  scopes:
    - 'openid'
    - 'profile'
    - 'email'
  response_types:
    - 'code'
  grant_types:
    - 'authorization_code'
  token_endpoint_auth_method: 'client_secret_post'
```

Generate the secret and its hash the same way Vikunja's `.env.example`
documents:

```bash
SECRET=$(openssl rand -base64 32)
docker exec authelia authelia crypto hash generate pbkdf2 --password "$SECRET"
# $SECRET (plaintext) goes into homeserver.yaml below.
# The printed hash goes into identity_providers.yml above.
```

Then `docker restart authelia`.

**Add the provider to `homeserver.yaml`** (same file as steps 1-2 above),
using the plaintext `$SECRET`:

```yaml
oidc_providers:
  - idp_id: authelia
    idp_name: "Authelia"
    idp_brand: "authelia"
    issuer: "https://auth.${DOMAIN}"
    client_id: "matrix"
    client_secret: "<plaintext $SECRET from above>"
    scopes: ["openid", "profile", "email"]
    # Link an SSO login to a pre-existing account with the same localpart
    # (e.g. one you already created via register_new_matrix_user in step 4)
    # instead of refusing and offering a "yourname1"-style fallback. Safe
    # here because the localpart only ever matches when the same person
    # already controls both the LDAP/Authelia account and the Matrix one.
    allow_existing_users: true
    user_mapping_provider:
      config:
        localpart_template: "{{ user.preferred_username }}"
        display_name_template: "{{ user.name }}"
        email_template: "{{ user.email }}"
    client_auth_method: client_secret_post
    # Authelia's ID token only carries "sub" - the rest of the profile
    # (preferred_username, name, email) is only on the userinfo endpoint.
    # Synapse's default ("auto") skips fetching userinfo whenever "openid"
    # is in scopes - which it always is here - so without this, every
    # login fails with "localpart is invalid: " (empty) once it gets past
    # the client_auth_method issue below.
    user_profile_method: userinfo_endpoint
```

Note the key here is `client_auth_method`, **not** `token_endpoint_auth_method`
(that name is only correct in Authelia's own client config above). Synapse
doesn't validate unknown `oidc_providers` keys at startup - it just silently
ignores a wrong key name and falls back to its default,
`client_secret_basic`. Since Authelia's client above only allows
`client_secret_post`, that mismatch doesn't surface until a user actually
completes a login and Synapse tries the token exchange - it fails there
with `invalid_client` on Authelia's error page. Startup logs looking clean
(OIDC metadata preloaded fine) does NOT mean this part is right - actually
click through a login to confirm, twice: once to hit the auth-method bug,
once to hit the userinfo/localpart bug above. Both are silent at startup
and only surface mid-login.

Then `docker restart synapse`. Check it logs `Preloading OIDC provider
'oidc-authelia'` and two `200`s fetching Authelia's discovery doc and
JWKS - if either 404s or times out, double check `issuer` and that
Authelia is actually reachable from the `anarchy-pizza` network.

**Important**: this does *not* replace closed registration/step 4's admin
CLI flow, it adds to it - both work side by side. But SSO logins
auto-provision a new Matrix account on first login for **anyone Authelia
lets through** (i.e. anyone in LLDAP), regardless of `enable_registration:
false` - that flag only gates the native password-registration path. The
actual access gate for SSO-created accounts is LLDAP membership, not
anything in this file.

Verify it worked:

```bash
curl -s https://matrix.${DOMAIN}/_matrix/client/v3/login | python3 -m json.tool
# should list a "m.login.sso" flow with identity_providers: [{"id": "oidc-authelia", ...}]
```

Element (web or app) will then show a "Continue with Authelia" button on
its login screen automatically - no client-side config needed.
