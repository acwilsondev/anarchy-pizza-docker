# anarchy-pizza-docker

This repo contains docker compose files for this project. Each app is in its own directory and has its own docker-compose file, so you can run them individually or all together.

## File Storage

I keep my storage on a dedicated drive seperate from the project. For instance, `bandcampsync` has the following volumes:

```yaml
    volumes:
      - /storage/appdata/bronze/bandcampsync:/config
      - /storage/media/music:/downloads
```

The first part of each volume is the path on the host machine, and the second part is the path in the container. You should change the host path to match your setup.

## Suggested order to run the apps

1. **Portainer** - this is a container management tool that will help you manage the other containers, clean up after them, etc. You can use Portainer to easily tear down containers and review logs. [docker-compose](apps/portainer/docker-compose.yml)
2. **NPM (Optional)** - Node Proxy Manager is a reverse proxy that will allow you to access the other apps via a domain name instead of an IP address. This is optional, but it makes it easier to remember the URLs for the apps. [docker-compose](apps/npm/docker-compose.yml)
3. **filebrowser** - this is a file manager that will allow you to upload files to the server. You can use this to upload the files for the other apps. [docker-compose](apps/filebrowser/docker-compose.yml)

With these installed, you'll have an easier time setting up the other apps.

## Setting up backups
