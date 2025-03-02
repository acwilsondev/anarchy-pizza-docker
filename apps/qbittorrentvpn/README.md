# qBittorrent VPN

This directory contains the Docker Compose configuration for running qBittorrent with integrated VPN support.

## Features

- qBittorrent BitTorrent client
- Integrated VPN (OpenVPN or WireGuard)
- Privoxy HTTP proxy
- microsocks SOCKS proxy
- IP leak protection

## Setup Instructions

1. Edit the `.env` file and fill in your VPN credentials and configuration details
2. For OpenVPN:
   - Download the OpenVPN configuration files from your VPN provider
   - Create a directory: `mkdir -p ./config/openvpn`
   - Extract the OpenVPN files to the `./config/openvpn/` directory
   - Make sure there is only one .ovpn file in the directory
3. For WireGuard:
   - For PIA: The configuration will be auto-generated after first run
   - For other providers: 
     - Create a directory: `mkdir -p ./config/wireguard`
     - Place your WireGuard configuration file in `./config/wireguard/`
   - Special note: **When using WireGuard**, modify the docker-compose.yml file to replace `cap_add: - NET_ADMIN` with:
     ```yaml
     privileged: true
     sysctls:
       - net.ipv4.conf.all.src_valid_mark=1
     ```

## Usage

- qBittorrent WebUI: http://localhost:8080 (default credentials: admin/[check logs for password])
- Privoxy HTTP Proxy: http://localhost:8118
- microsocks SOCKS5 Proxy: localhost:9118 (default credentials: admin/socks)

## Notes

- The default WebUI password can be found in the logs: `docker-compose logs`
- Data is stored in the `./data` directory
- Configuration is stored in the `./config` directory
