# anarchy-pizza-docker

This repo contains Docker Compose files for this project. Each app is in its own directory and has its own Docker Compose file, so you can run them individually or all together.

## Prerequisites

- Docker Engine + Docker Compose v2
- A host filesystem path for persistent volumes

## Quick start

From the repo root, you can run a single app like this:

```bash
cd apps/portainer
docker compose up -d
```

To update and restart every app that has a compose file, you can use:

```bash
./update-all-apps.sh
```

## File Storage

I keep my storage on a dedicated drive separate from the project. For instance, `bandcampsync` has the following volumes:

```yaml
    volumes:
      - /storage/appdata/bronze/bandcampsync:/config
      - /storage/media/music:/downloads
```

The first part of each volume is the path on the host machine, and the second part is the path in the container. You should change the host path to match your setup.

## Suggested order to run the apps

1. **Portainer** - this is a container management tool that will help you manage the other containers, clean up after them, etc. You can use Portainer to easily tear down containers and review logs. [docker-compose](apps/portainer/docker-compose.yml)
2. **NPM (Optional)** - Nginx Proxy Manager is a reverse proxy that will allow you to access the other apps via a domain name instead of an IP address. This is optional, but it makes it easier to remember the URLs for the apps. [docker-compose](apps/npm/docker-compose.yml)
3. **filebrowser** - this is a file manager that will allow you to upload files to the server. You can use this to upload the files for the other apps. [docker-compose](apps/filebrowser/docker-compose.yml)

With these installed, you'll have an easier time setting up the other apps.

## Setting up backups

Consider backing up the host-side volume directories (for example, `/storage/appdata/bronze/...`) along with any shared media paths such as `/storage/media/...`. If you're using a dedicated drive, snapshot or sync it regularly. A simple approach is to use `rsync` or a backup tool like Borg or Restic to copy the volume directories to another disk or remote host.
