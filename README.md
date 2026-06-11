# UniFi OS Server Docker

Docker image for running UniFi OS Server with support for multiple versions.

> This repository provides a solution for running UniFi OS Server (UOS) in Docker, addressing the challenge of using Docker instead of the Podman-based containerization that is shipped by Ubiquiti. This allows users to deploy UOS on platforms with standard Docker tooling, bypassing the limitations of the official Podman setup.

## Why This Exists

Ubiquiti ships UOS as a Podman-based appliance image tightly coupled to their hardware. Running it on commodity servers or existing Docker infrastructure requires extracting the rootfs, wiring up networking and databases yourself, and managing systemd inside a container. This project automates all of that into a single `docker build`.

By default the internal mongod is removed and the container expects a separate MongoDB 4.4 instance (see the included `docker-compose.yaml`). Set `MONGO_INTERNAL=true` to keep the bundled mongod instead.

## Quick Start

```bash
docker run -d --name unifi-os-server --privileged --cgroupns=host \
  --cap-add NET_RAW --cap-add NET_ADMIN \
  --tmpfs /run:exec --tmpfs /run/lock --tmpfs /tmp:exec \
  --tmpfs /var/lib/journal --tmpfs /var/opt/unifi/tmp:size=64m \
  --tmpfs /data/unifi-core/config/http \
  -e UOS_SYSTEM_IP="<your-public-ip>" \
  -e MONGO_INTERNAL=true \
  -p 443:443 -p 8443:8443 -p 8080:8080 -p 3478:3478/udp \
  whaamed/unifi-os-server
```

The Web UI will be available at `https://localhost:443` once the container is ready.

## Ports

| Port | Protocol | Description |
|------|----------|-------------|
| 443 | TCP | UniFi Web UI (HTTPS) |
| 8443 | TCP | UniFi Controller API |
| 8444 | TCP | UniFi Controller (alternate) |
| 8080 | TCP | HTTP inform / redirect |
| 8880 | TCP | Guest portal (HTTP) |
| 8881 | TCP | Guest portal (HTTPS) |
| 8882 | TCP | Guest portal (alternate) |
| 6789 | TCP | Speed test |
| 11084 | TCP | Remote adoption |
| 5671 | TCP | AMQP (RabbitMQ) |
| 9543 | TCP | Internal service |
| 3478 | UDP | STUN |
| 5514 | UDP | Syslog |
| 10003 | UDP | UniFi discovery |
| 7443 | TCP | Network App bypass (localhost only, requires `EXPOSE_NETWORK_APP=true`) |
| 5432 | TCP | PostgreSQL (localhost only) |

## Environment Variables

| Variable | Default | Required | Description |
|----------|---------|----------|-------------|
| `TZ` | — | No | Container timezone (e.g. `Europe/Amsterdam`) |
| `UOS_SYSTEM_IP` | — | **Yes** | System IP written to UniFi `system.properties` |
| `UOS_UUID` | auto-generated | No | Persistent UUID for the UOS instance |
| `UOS_SERVER_VERSION` | `5.0.6` | No | UOS version string (set at build time) |
| `FIRMWARE_PLATFORM` | `linux-custom` | No | Platform identifier (set at build time) |
| `EXPOSE_NETWORK_APP` | `false` | No | Inject nginx bypass on port 7443 directly to Network App, skipping UOS SSO |
| `MONGO_INTERNAL` | `false` | No | `true` keeps the internal mongod; `false` uses an external MongoDB |
| `MONGO_HOST` | `unifi-os-server-mongodb` | No | External MongoDB hostname |
| `MONGO_PORT` | `27017` | No | External MongoDB port |
| `MONGO_USER` | — | No | MongoDB username |
| `MONGO_PASS` | — | No | MongoDB password |
| `MONGO_TLS` | `false` | No | Enable TLS for the MongoDB connection |
| `MONGO_AUTH_SOURCE` | `admin` | No | MongoDB authentication database |


## How It Works

The build downloads the official UOS installer binary, extracts the embedded OCI image using `binwalk`, flattens its layers into a rootfs, and layers the entrypoint on top. At runtime the entrypoint configures MongoDB, sets up networking (macvlan `eth0` alias), exposes PostgreSQL, and hands off to systemd.

---

This project is not affiliated with, endorsed by, or supported by Ubiquiti Inc. All trademarks and copyrights belong to their respective owners.