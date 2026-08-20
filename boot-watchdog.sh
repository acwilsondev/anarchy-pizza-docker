#!/bin/bash
#
# Recovers containers left Exited after a host reboot. dockerd's boot-time
# container-restore step tries each restart-policy container exactly once;
# if that attempt fails (e.g. a host-port bind racing another service that
# hasn't come up yet), the container is left Exited with no further
# retries - and if the failure was in network setup, `docker start` alone
# won't reattach it, only a full `docker compose up -d` recreate will.
# See incidents/2026-08-09-lldap-authelia-outage.md.
#
# Run a couple of minutes after boot via `@reboot` in cron (deliberately
# not a systemd unit, so this needs no root):
#   @reboot sleep 120 && /home/aaron/homelab-docker/boot-watchdog.sh >> /home/aaron/homelab-docker/boot-watchdog.log 2>&1

set -uo pipefail

log() { echo "$(date -u +%FT%TZ) $*"; }

exited=$(docker ps -a -q --filter "status=exited")
if [ -z "$exited" ]; then
  log "no exited containers"
  exit 0
fi

for cid in $exited; do
  name=$(docker inspect "$cid" --format '{{.Name}}' | sed 's#^/##')
  policy=$(docker inspect "$cid" --format '{{.HostConfig.RestartPolicy.Name}}')

  case "$policy" in
    unless-stopped|always)
      workdir=$(docker inspect "$cid" --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}')
      envfiles=$(docker inspect "$cid" --format '{{index .Config.Labels "com.docker.compose.project.environment_file"}}')

      if [ -n "$workdir" ] && [ -d "$workdir" ]; then
        log "recovering $name via compose in $workdir"
        env_args=()
        IFS=',' read -ra files <<< "$envfiles"
        for f in "${files[@]}"; do
          [ -n "$f" ] && env_args+=(--env-file "$f")
        done
        (cd "$workdir" && docker compose "${env_args[@]}" up -d)
      else
        log "recovering $name via docker start (no compose working_dir label found)"
        docker start "$name"
      fi
      ;;
    *)
      log "skipping $name (restart policy: ${policy:-none})"
      ;;
  esac
done
