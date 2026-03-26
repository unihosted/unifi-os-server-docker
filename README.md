# UniFi OS Server Docker

[![GitHub Release](https://img.shields.io/github/v/release/unihosted/unifi-os-server-docker)](https://github.com/unihosted/unifi-os-server-docker/releases)
[![GitHub Container Registry](https://img.shields.io/badge/GHCR-Container%20Image-blue)](https://github.com/unihosted/unifi-os-server-docker/pkgs/container/unifi-os-server-docker)
[![Build Status](https://github.com/unihosted/unifi-os-server-docker/workflows/Extract%20UniFi%20OS%20Server%20base%20image%20and%20build%20Docker%20image/badge.svg)](https://github.com/unihosted/unifi-os-server-docker/actions)
[![License](https://img.shields.io/github/license/unihosted/unifi-os-server-docker)](LICENSE)

A Docker containerization of [UniFi OS Server](https://ui.com/download?platform=unifi-os-server) - the network management platform from Ubiquiti. This project enables running the UniFi Network Controller in a containerized environment with external MongoDB support and direct API access capabilities.

## Features

- **Containerized UniFi OS Server** - Run UniFi Network Controller in Docker
- **External MongoDB** - Separate MongoDB container for data persistence
- **Localhost Bypass** - Direct API access on port 7443 without SSO authentication
- **PostgreSQL Exposed** - Access PostgreSQL database externally (port 5432)
- **Synology Support** - Specific patches for Synology NAS hardware
- **Systemd Init** - Full systemd support for proper service management

## Quick Start

### Prerequisites

- Docker 20.10+
- Docker Compose 2.0+
- Linux host (amd64 architecture)

### Installation

1. Clone the repository:
```bash
git clone https://github.com/unihosted/unifi-os-server-docker.git
cd unifi-os-server-docker
```

2. Copy the environment template:
```bash
cp .env.example .env
```

3. Edit `.env` and set your configuration (especially `UOS_SYSTEM_IP`):
```bash
# Set your server's public IP address
UOS_SYSTEM_IP=your.server.ip.address
```

4. Start the services:
```bash
docker compose up -d
```

5. Access the UniFi Network Controller:
   - Web UI: `https://localhost:11443` (or your server IP)
   - API (bypass): `https://localhost:7443`

## Configuration

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `UOS_SYSTEM_IP` | **Required** - Your server's public IP address | - |
| `UOS_UUID` | Device UUID (auto-generated if not set) | Auto-generated |
| `MONGO_HOST` | MongoDB hostname | `unifi-os-server-mongodb` |
| `MONGO_PORT` | MongoDB port | `27017` |
| `MONGO_USER` | MongoDB username | `root` |
| `MONGO_PASS` | MongoDB password | `root` |
| `MONGO_TLS` | Enable MongoDB TLS | `false` |
| `MONGO_AUTH_SOURCE` | MongoDB authentication database | `admin` |
| `TZ` | Timezone | `Europe/Amsterdam` |

### Ports

| Port | Protocol | Description |
|------|----------|-------------|
| 3478 | UDP | STUN service |
| 5514 | UDP | Syslog |
| 8080 | TCP | HTTP redirect |
| 8880 | TCP | HTTP portal |
| 11443 | TCP | HTTPS Web UI |
| 7443 | TCP | Localhost API bypass |
| 5432 | TCP | PostgreSQL |
| 6789 | TCP | Speed test |
| 11084 | TCP | API |

### Volumes

| Host Path | Container Path | Description |
|-----------|----------------|-------------|
| `./volume` | `/var/lib/uosserver` | UniFi OS data |
| `./volume` | `/var/lib/unifi` | UniFi controller data |
| `mongodb-data` (named) | `/data/db` | MongoDB data |

## API Access

### Localhost Bypass (Port 7443)

The container includes a localhost bypass that allows direct API access without SSO authentication:

```bash
# Example: Get sites
curl -k -H "X-Csrf-Token: <token>" \
  https://localhost:7443/proxy/network/api/self/sites
```

This is useful for:
- Automated scripts
- Third-party integrations
- Direct API access without web login

## Building from Source

### Using Docker Compose

```bash
docker compose build
docker compose up -d
```

### Using GitHub Actions (Recommended)

The repository includes a GitHub Actions workflow that:
1. Downloads the official UniFi OS Server installer
2. Extracts the base image using binwalk
3. Builds and publishes to GitHub Container Registry

To trigger a build:
1. Go to **Actions** → **Extract UniFi OS Server base image and build Docker image**
2. Click **Run workflow**
3. Specify the installer URL and version
4. The image will be published to `ghcr.io/unihosted/unifi-os-server-docker`

## Versioning

This project follows [Semantic Versioning](https://semver.org/):

- **MAJOR**: Breaking changes (e.g., new UniFi OS major version)
- **MINOR**: New features, non-breaking changes
- **PATCH**: Bug fixes, security updates

### Available Tags

| Tag | Description |
|-----|-------------|
| `latest` | Latest stable release |
| `5.0.6` | Specific version |
| `5.0` | Latest 5.0.x patch |
| `5` | Latest 5.x minor |

## Troubleshooting

### Container won't start

Check the logs:
```bash
docker compose logs -f unifi-os-server
```

### MongoDB connection issues

Ensure MongoDB is healthy:
```bash
docker compose ps
```

### Synology specific issues

The container automatically detects Synology hardware and applies necessary systemd overrides for PostgreSQL, RabbitMQ, and ulp-go services.

## Contributing

Contributions are welcome! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## License

This project is licensed under the MIT License - see [LICENSE](LICENSE) for details.

## Disclaimer

This is an unofficial community project. UniFi and Ubiquiti are trademarks of Ubiquiti Inc. This project is not affiliated with or endorsed by Ubiquiti Inc.

## Support

- [GitHub Issues](https://github.com/unihosted/unifi-os-server-docker/issues)
- [Discussions](https://github.com/unihosted/unifi-os-server-docker/discussions)

## Related Projects

- [UniFi Docker](https://github.com/jacobalberty/unifi-docker) - Alternative UniFi Controller Docker image
- [UniFi Network Application](https://github.com/linuxserver/docker-unifi-network-application) - LinuxServer.io's UniFi image
