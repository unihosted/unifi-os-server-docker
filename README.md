# UniFi OS Server in Docker

> This repository provides a solution for running UniFi OS Server (UOS) in Docker, addressing the challenge of using Docker instead of the Podman-based containerization that is shipped by Ubiquiti. This allows users to deploy UOS on platforms with standard Docker tooling, bypassing the limitations of the official Podman setup.

## Quick Start

Save the compose below as `docker-compose.yaml`, set `UOS_SYSTEM_IP` to your public IP, and run `docker compose up -d`. The Web UI will be at `https://localhost:443` once the container is ready. Every port and environment variable is documented inline: the compose *is* the reference.

```yaml
services:
  unifi-os-server:
    container_name: unifi-os-server
    image: whaamed/unifi-os-server
    privileged: true
    cgroup: host
    cap_add:
      - NET_RAW
      - NET_ADMIN
    ports:
      - "443:443"            # UniFi Web UI (HTTPS)
      - "8443:8443"          # UniFi Controller API
      - "8444:8444"          # UniFi Controller (alternate)
      - "8080:8080"          # HTTP inform / redirect
      - "8880:8880"          # Guest portal (HTTP)
      - "8881:8881"          # Guest portal (HTTPS)
      - "8882:8882"          # Guest portal (alternate)
      - "6789:6789"          # Speed test
      - "11084:11084"        # Remote adoption
      - "5671:5671"          # AMQP (RabbitMQ)
      - "9543:9543"          # Internal service
      - "3478:3478/udp"      # STUN
      - "5514:5514/udp"      # Syslog
      - "10003:10003/udp"    # UniFi discovery (local network only)

      # Network App bypass: skips UOS SSO for direct controller API access.
      # Bind to localhost ONLY; never expose publicly.
      - "127.0.0.1:7443:7443"  # requires EXPOSE_NETWORK_APP=true
      - "127.0.0.1:5432:5432"  # PostgreSQL (localhost only)

    volumes:
      - ./docker/uos:/var/lib/uosserver
      - ./docker/uos:/var/lib/unifi
      - ./docker/data/:/data
    tmpfs:
      - /run:exec
      - /run/lock
      - /tmp:exec
      - /var/lib/journal
      - /var/opt/unifi/tmp:size=64m
      - /data/unifi-core/config/http
    networks:
      - unifi-os
    depends_on:
      - unifi-network-mongodb
    environment:
      TZ: Europe/Amsterdam            # Container timezone
      UOS_SYSTEM_IP: "203.0.113.10"   # REQUIRED: your public IP, written to system.properties
      UOS_UUID: ""                    # Auto-generated if left blank; persistent across restarts
      UOS_SERVER_VERSION: "5.0.6"     # UOS version string (set at build time)
      FIRMWARE_PLATFORM: "linux-custom" # Platform identifier (set at build time)

      EXPOSE_NETWORK_APP: "false"     # true → nginx bypass on port 7443, skips UOS SSO

      # --- External MongoDB ---
      # MONGO_INTERNAL=false uses the MongoDB service below.
      # Set MONGO_INTERNAL=true to let the Network App run its own mongod
      # (port 27117) and remove the unifi-network-mongodb service + depends_on.
      MONGO_INTERNAL: "false"
      MONGO_HOST: "unifi-network-mongodb" # External MongoDB hostname
      MONGO_PORT: "27017"               # External MongoDB port
      MONGO_USER: ""                    # MongoDB username
      MONGO_PASS: ""                    # MongoDB password
      MONGO_TLS: "false"                # Enable TLS for the MongoDB connection
      MONGO_AUTH_SOURCE: "admin"        # MongoDB authentication database

  unifi-network-mongodb:
    container_name: unifi-os-server-mongodb
    image: mongo:4.4
    networks:
      - unifi-os
    volumes:
      - ./docker/mongodb:/data/db

networks:
  unifi-os:
```


## Why This Exists

Ubiquiti ships UOS as a Podman image because Podman is the container platform they happen to use. At UniHosted we were already running everything else in Docker, so rather than maintain a parallel Podman setup just for one application, we figured out how to convert that Podman image into a Docker image. Once the pipeline worked, it seemed silly not to share it. If you're in the same boat, here it is.

By default the internal mongod is removed and the container expects a separate MongoDB 4.4 instance (see the included `docker-compose.yaml`). Set `MONGO_INTERNAL=true` to let the UniFi Network App manage its own bundled mongod (port 27117) instead.

## How It Works

One of the nice things about this project is that the build is fully transparent: nothing happens behind a curtain. We download the official Ubiquiti UOS installer, extract the embedded Podman image (which is already in OCI format), and flatten its layers into a rootfs that Docker can use. In other words, we're not distributing or re-distributing any Ubiquiti code; we're converting an image from one container format to another. Our own entrypoint is layered on top, and at runtime it configures MongoDB, wires up networking (macvlan `eth0` alias), exposes PostgreSQL, and hands off to systemd. The entire pipeline runs through the [`build-image`](.github/workflows/build-image.yml) GitHub Action, so you can inspect exactly what happens at every step.

---

This project is not affiliated with, endorsed by, or supported by Ubiquiti Inc. All trademarks and copyrights belong to their respective owners.
