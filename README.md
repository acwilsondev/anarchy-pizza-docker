# Anarchy Pizza Docker Reference 🍕

This repository is a curated collection of Docker Compose configurations for various self-hosted applications. It's designed as a "Reference Architecture" to help friends and fellow enthusiasts set up a robust, portable, and easily maintainable home server stack.

## ✨ Key Features

- **Standardized Structure**: Each app lives in its own directory with its own `docker-compose.yml`.
- **Portable Storage**: All host paths are externalized via variables (`STORAGE_ROOT`, `MEDIA_ROOT`).
- **Zero-Downtime Updates**: A custom script updates containers only when new images or config changes are detected.
- **Shared Reverse Proxy**: Pre-configured to work with a shared external network (`anarchy-pizza`) for easy domain/SSL management.
- **Centralized Logging**: Includes **Dozzle** for a unified web-based view of all container logs.
- **Hardened Configs**: Includes resource limits and healthchecks for core services.

## 🛠️ Prerequisites

- **Docker Engine + Docker Compose v2**: Ensure you have the modern `docker compose` plugin installed.
- **Linux Environment**: Designed for Ubuntu/Debian, but adaptable to any system running Docker.
- **Basic Terminal Knowledge**: You'll need to be comfortable editing `.env` files and running scripts.

## 🚀 Getting Started

### 1. Clone and Initialize
```bash
git clone https://github.com/your-username/anarchy-pizza-docker.git
cd anarchy-pizza-docker
```

### 2. Configure Your Environment
Copy the example environment file and edit it to match your host system's paths and user IDs:
```bash
cp .env.example .env
nano .env
```
*   Set `STORAGE_ROOT` to where you want app data (configs, DBs) to live.
*   Set `MEDIA_ROOT` to your media library path.

### 3. Bootstrap the Network
Run the bootstrap script to create the shared `anarchy-pizza` network:
```bash
bash bootstrap.sh
```

### 4. Deploy Applications
You can start apps individually or all at once.

**To start a specific app:**
```bash
cd apps/portainer
docker compose up -d
```

**To update and start everything:**
```bash
bash update-all-apps.sh
```

## 🏗️ Architecture Overview

### Shared Network
Most apps connect to the `anarchy-pizza` external network. This allows a single Reverse Proxy (like **Nginx Proxy Manager**, included in `apps/npm`) to route traffic to any container using its container name as a hostname.

### Storage Strategy
We use a "Tiered" storage approach in the example configurations:
- `gold/`: Fast storage (SSD/NVMe) for databases and high-IO apps.
- `silver/`: Standard storage for general app configs.
- `bronze/`: Bulk storage for less sensitive or large data.

### Monitoring
Once the stack is running, you can visit `http://your-server-ip:8888` to access **Dozzle**, which provides real-time logs for all your containers in a beautiful web UI.

## ⚠️ Disclaimer

This is a **reference** repository. It reflects a specific personal setup and may require adjustments for your hardware, network, or security requirements. Always review the `docker-compose.yml` files before deployment.

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
