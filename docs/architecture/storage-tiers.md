# Storage tiers

- `local-path-provisioner` PVCs for small/medium app state (databases,
  configs).
- `hostPath` straight at the physical bulk-storage disk for large data
  that needs to stay off the OS/root volume (Calibre-web's book library,
  Open WebUI's Ollama models).

See `docs/architecture_record/2026-08-13-migrate-real-data.md` for the
concrete gotcha this split caught (Open WebUI's Ollama models almost
landing on the wrong disk) and
`docs/architecture_record/2026-08-13-close-out-known-blockers.md` for how
the tiering decision was reached.
