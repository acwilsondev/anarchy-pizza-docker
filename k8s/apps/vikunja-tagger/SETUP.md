# vikunja-tagger setup

Deploys the worker from [vikunja-tagger](https://github.com/acwilsondev/vikunja-tagger)
(kept as its own repo/image, not part of this one — see that repo's README
for what it does). This file is just the wiring: the k8s-side secret, the
Vikunja-side API token and webhook, and the one cross-app change it needed
(exposing Ollama's port from the `webui` service).

## 1. Expose Ollama's port on the `webui` service

Done already in `k8s/apps/webui/values.yaml` — the pod's Ollama sidecar
listens on `11434` but the Service previously only published `8080`
(the WebUI itself). Cross-namespace pods (this worker) need the `11434`
port published to reach it as
`webui.webui.svc.cluster.local:11434`. Nothing further to do here, just
noting why that diff is bundled with this app.

## 2. Create a Vikunja API token

In Vikunja: **Settings > API Tokens > Create**. Needs at minimum:
- `labels:read`
- `tasks:read`, `tasks:write` (to read task payloads and attach labels)

## 3. Create the k8s secret

Not tracked in git, same as every other app's secrets in this stack:

```bash
kubectl create namespace vikunja-tagger
kubectl -n vikunja-tagger create secret generic vikunja-tagger-secrets \
  --from-literal=VIKUNJA_API_TOKEN='<token from step 2>' \
  --from-literal=WEBHOOK_SECRET="$(openssl rand -hex 32)"
```

Save the `WEBHOOK_SECRET` value — you need the same string in step 4.

## 4. Register the webhook in Vikunja

Per project you want auto-tagging on: **Project > Webhooks > Create**.

- Target URL: `http://vikunja-tagger.vikunja-tagger.svc.cluster.local:8000/webhooks/vikunja`
  (cluster-internal — Vikunja calls this directly, pod to pod; it's
  deliberately not routed through Traefik/Authelia the way `n8n`'s public
  webhooks are, since the only caller is Vikunja itself, already inside the
  cluster)
- Event: `task.created`
- Secret: the `WEBHOOK_SECRET` value from step 3

## 5. Verify

Create a test task in that project. Check the worker's logs:

```bash
kubectl -n vikunja-tagger logs -l app.kubernetes.io/name=vikunja-tagger -f
```

If you see `invalid signature` on the very first delivery, Vikunja's HMAC
encoding didn't match what this worker expects (hex-encoded HMAC-SHA256 of
the raw body) — that was inferred from Vikunja's docs, not confirmed
against this exact instance yet, so double check `app/signature.py` in the
source repo against what actually arrives if it fails.

## Updating after a source change

The deploy tracks the `latest` tag, so Argo CD's self-heal won't notice a
new image on its own — restart the deployment after a push:

```bash
kubectl -n vikunja-tagger rollout restart deployment/vikunja-tagger
```
