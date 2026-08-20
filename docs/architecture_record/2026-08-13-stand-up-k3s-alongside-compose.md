# Stand up k3s alongside Compose (rollout step 1)

Done, 2026-08-13. First step of
`docs/architecture_record/2026-08-10-migrate-from-compose-to-k3s-helm-argocd.md`'s
rollout plan — no cutover yet, Compose stack stays the live path throughout.

k3s (Traefik/ServiceLB disabled to avoid the port 80/443 conflict), Helm,
and Argo CD are installed and running on the same box. Argo CD watches this
repo (`k8s/apps/`, app-of-apps root at `k8s/argocd/root-app.yaml`, read-only
deploy key) with automated sync + prune + self-heal. The GitOps loop was
proven end-to-end with a throwaway smoke-test app — pushed, synced, served
traffic, then removed from git and auto-pruned from the cluster — and has
since been deleted, leaving `k8s/apps/` empty and ready for the first real
migration.

The Compose stack was never touched: all 18 containers stayed up and were
not restarted or reconfigured at any point during this step.
