# Migrate real data, not fresh/empty (rollout step 5, part 2)

Done, 2026-08-13, alongside
`docs/architecture_record/2026-08-13-migrate-remaining-apps.md`. Per the
call to prioritize full parity over a quick fresh cutover: real data
copied in for every app that had any, via the same
backup → stop-Compose-container → copy-into-k8s-PVC → restart pattern
established for LLDAP in
`docs/architecture_record/2026-08-13-migrate-the-sso-critical-path.md`
(file copy for LLDAP/Vaultwarden/FreshRSS/Calibre-web/Homarr/Open WebUI's
chat history; `pg_dump`/`pg_restore` for Vikunja and Synapse's
Postgres-backed data, since raw file copy isn't safe for a live database
and isn't needed — dump/restore only moves data, not credentials, so the
fresh k8s DB passwords never needed to match production's).

- Open WebUI's Ollama models (~55GB) are a `hostPath` straight at the
  real `bronze/ollama` directory, **not** a PVC — k3s's
  `local-path-provisioner` defaults to the OS disk
  (`/var/lib/rancher/k3s/storage`, on the root LVM volume), not the
  dedicated bulk-storage disk (`/storage`, `/dev/sda`) this repo's
  tiering actually lives on. Copying 55GB onto the wrong disk was
  caught before doing it, not after.
- Matrix/Synapse real gotcha: assumed `server_name` matched the bare
  domain (`anarchy.pizza`) — wrong, production has always used
  `matrix.anarchy.pizza` (`SYNAPSE_SERVER_NAME` in the Compose `.env`).
  Synapse correctly refused to start against the restored real database
  ("Found users in database not native to anarchy.pizza") until fixed.
- Two real secret-handling mistakes happened along the way and are
  worth remembering rather than burying: a `base64 -d | head` command
  printed the real Authelia OIDC `hmac_secret` and part of the RSA
  signing key into the session transcript (both regenerated
  immediately, treated as compromised); and reading FreshRSS's `.env`
  with `cat` printed the real admin password (not regenerated, but
  flagged for rotation — it's an already-known account password, not a
  newly-exposed one). Lesson: redirect secret reads to files/variables,
  never let them hit a place you'll read directly, even mid-migration
  under time pressure.
- Authelia's own internal `db.sqlite3` (sessions, regulation/ban state,
  any TOTP registrations) was **not** migrated — wasn't in the original
  data list, and this stack uses `one_factor` everywhere (no TOTP
  enforced), so there's little to lose. Flagged, not silently dropped.
