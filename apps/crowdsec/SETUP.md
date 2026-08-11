# CrowdSec setup

Unlike most apps here, this one has a real chicken-and-egg bootstrap order:
crowdsec has to be running before it can hand out a bouncer key, and Traefik
needs that key before it can load the plugin that actually enforces bans.
Follow this order, not `update-all-apps.sh`, the first time.

## 1. Bring crowdsec up alone

```bash
cd apps/crowdsec
cp .env.example .env
docker compose --env-file ../../.env --env-file .env up -d
```

`COLLECTIONS` in `docker-compose.yml` installs on first boot. Confirm it
worked:

```bash
docker exec crowdsec cscli collections list
docker exec crowdsec cscli metrics
```

You should see `crowdsecurity/traefik`, `crowdsecurity/http-cve`, and
`Dominic-Wagner/vaultwarden` listed.

## 2. Generate the Traefik bouncer key

```bash
docker exec crowdsec cscli bouncers add traefik-bouncer
```

Copy the printed key into `apps/crowdsec/.env` as `CROWDSEC_BOUNCER_KEY`,
then re-apply so the middleware label picks it up:

```bash
docker compose --env-file ../../.env --env-file .env up -d
```

## 3. Enroll with the CrowdSec Console (community blocklist)

This step needs an account of yours, so it can't be scripted end-to-end:

1. Create a free account at https://app.crowdsec.net and generate an
   enrollment key for a new instance.
2. `docker exec crowdsec cscli console enroll <your-enroll-key>`
3. `docker exec crowdsec cscli console enable` to accept the recommended
   sharing options (this is what gets you the community blocklist in
   exchange for anonymized signal from this box).
4. Approve the enrollment request in the Console web UI.

## 4. Bring Traefik up with the new static config

Traefik's `docker-compose.yml` now loads the bouncer plugin and applies it
at the entrypoint level, so every router behind Traefik gets protected
automatically - no per-app labels needed.

```bash
cd ../traefik
docker compose --env-file ../../.env up -d
docker compose logs traefik
```

Watch the logs for plugin-load errors (bad module version, LAPI
unreachable) before considering this done - a bad plugin config can take
Traefik itself down.

## 5. Verify it actually blocks something

```bash
docker exec crowdsec cscli decisions list
docker exec crowdsec cscli bouncers list   # confirm traefik-bouncer shows "last pull" recently
```

Trip a scenario for real - a handful of rapid bad-password attempts against
`vault.${DOMAIN}`'s login, or a burst of requests to nonexistent paths on
any public host - then confirm the source IP shows up in
`cscli decisions list` and subsequently gets a `403` straight from Traefik
(`curl -I` from that IP, or `cscli decisions add --ip <your-own-ip> --duration 1m`
as a safe self-test that won't lock anyone else out).

## After this is set up

`update-all-apps.sh` will pull/restart crowdsec like every other app in
`apps/` from here on - the manual ordering above is only needed once.
