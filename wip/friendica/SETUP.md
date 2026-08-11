# Friendica setup - private first, federated later

Friendica is a federated (ActivityPub) social network - the whole point
is that other servers on the internet can push posts, follows, and
replies to yours. Deliberately starting it **not** federated for a
while, then flipping it on once you trust the setup, doesn't map onto
this repo's usual "copy `.env.example`, `up -d`, done" flow the way a
self-contained app does. Two things make it different:

- **Friendica's base URL can't reliably change after install.** It's
  baked into the database and used for session/CSRF validation, not
  just link generation - the project's own docs and issue tracker warn
  that changing it later leaves the site in a broken state. So unlike
  a normal "get it running internally, expose it later" rollout, the
  real `FRIENDICA_URL` (`https://friendica.${DOMAIN}`) has to be
  correct from the very first install, which means DNS + a real TLS
  cert exist from day one.
- **There's no in-app "disable federation" switch.** Unlike this
  repo's Matrix setup (which drops the federation *listener* entirely -
  see `apps/matrix/SETUP.md`), ActivityPub is core to Friendica, not an
  addon you can turn off, and it shares the same web port as everything
  else. So federation is turned off here at the access layer instead:
  **Authelia's forward-auth gate sits in front of every path**,
  including `/inbox` and `/.well-known/webfinger`. A remote Mastodon/
  Pleroma/etc. server trying to deliver or discover anything gets
  redirected to an Authelia login page it has no way to pass, so
  nothing gets in or out. This is the same "Forward-auth gate" pattern
  already used for Dozzle/Uptime Kuma/SearXNG (see main README) - just
  applied here for a different reason (blocking federation, not
  replacing a login form).

DNS being public and the cert showing up in Certificate Transparency
logs is normal for every app in this stack, not a new exposure - the
Authelia gate, not secrecy of the hostname, is what's actually keeping
this instance closed for now.

This directory lives under `wip/`, not `apps/`, on purpose:
`update-all-apps.sh` only walks `apps/*/`, so this stays inert and
won't get pulled/recreated by that script (or picked up as "active" per
the main README) until you're ready and move it there
(`git mv wip/friendica apps/friendica`). Until then, everything below
still works fine run directly from `wip/friendica/` — the relative
`../../.env` path resolves the same either way.

## 1. Configure

```bash
cd wip/friendica
cp .env.example .env
# edit .env: FRIENDICA_URL (real domain), FRIENDICA_ADMIN_MAIL, and a
# real MYSQL_PASSWORD/MARIADB_PASSWORD/MARIADB_ROOT_PASSWORD (e.g.
# `openssl rand -base64 24`) - MYSQL_* and MARIADB_* pairs must match.
```

## 2. DNS

Point `friendica.${DOMAIN}` (A/AAAA) at the server, same as every other
Traefik-routed app - required now, not later, per the base-URL note
above.

## 3. Start it

```bash
docker compose --env-file ../../.env --env-file .env up -d
```

The `friendica` container auto-installs on first boot once it sees
`MYSQL_*`, `FRIENDICA_ADMIN_MAIL`, and `FRIENDICA_URL` all set - no
install wizard to click through. `friendica-worker` runs the same image
as a dedicated background-task loop (notifications, thumbnails,
delivery queue, etc. - Friendica doesn't function correctly without
it); `friendica-mariadb` is the database (Friendica only supports
MySQL/MariaDB, not the Postgres this repo defaults to elsewhere).

## 4. Log in

Visit `https://friendica.${DOMAIN}` - you'll hit Authelia first (same
login as every other forward-auth app here), then Friendica's own login
screen. Log in with the admin email/password Friendica generated on
install (check the `friendica` container's logs for the generated
password if you didn't set one explicitly).

**Close registration** - Admin Panel → Site → Registration → set to
*Closed* (or *Requires approval*). Nothing about the Authelia gate
stops someone who already has an LDAP account on this host from
registering a Friendica account too; closing registration is the actual
control. `apps/authelia/configuration.yml` also has a `friendica`
access-control rule denying the `users` LDAP group by default (only
`admins` can get past Authelia at all) - loosen that first if you
intend for anyone but yourself to reach it.

## 5. Going public / federated later

When you're ready to actually join the fediverse:

1. Remove the one `friendica-secure` `middlewares=authelia@docker`
   label line from `docker-compose.yml` (leave the plain `friendica`
   router's line alone if you want the http→https redirect to still
   require auth - or drop both to open it up fully).
2. Recreate: `docker compose --env-file ../../.env --env-file .env up -d`.
3. In Friendica's admin panel, review Site → Relocate/Federation
   settings and the public directory submission setting before you're
   discoverable.

No reinstall, no URL change - the base URL was already correct.
