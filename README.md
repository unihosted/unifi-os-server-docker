# UniFi OS Server in Docker

> This repository provides a solution for running UniFi OS Server (UOS) in Docker, addressing the challenge of using Docker instead of the Podman-based containerization that is shipped by Ubiquiti. This allows users to deploy UOS on platforms with standard Docker tooling, bypassing the limitations of the official Podman setup.

## Quick Start

Save the compose below as `docker-compose.yaml`, set `UOS_SYSTEM_IP` to your public IP, and run `docker compose up -d`. The Web UI will be at `https://localhost:11443` once the container is ready. Every port and environment variable is documented inline: the compose *is* the reference.

```yaml
services:
  unifi-os-server:
    container_name: unifi-os-server
    image: ghcr.io/unihosted/unifi-os-server-docker:latest
    cgroup: host
    restart: unless-stopped
    cap_add:
      - NET_RAW
      - NET_ADMIN
    ports:
      - "8080:8080" # HTTP inform / redirect
      - "8443:8443" # UniFi Controller API
      - "8444:8444" # Secure Portal for Hotspot
      - "8880-8882:8880-8882" # Hotspot portal redirection (HTTP)
      - "10003:10003/udp" # UniFi discovery (Only needed on local network)
      - "11443:443" # UniFi Web UI (HTTPS)
      - "3478:3478/udp" # STUN used for device poking
      - "5514:5514/udp" # Syslog
      - "6789:6789" # Speed test

      # Network App bypass — skips UOS SSO, direct access to the controller
      # API on 127.0.0.1:8081.  Bind to localhost ONLY; never expose publicly.
      - "127.0.0.1:7443:7443"
      - "127.0.0.1:5432:5432" # PostgreSQL (localhost only)
    extra_hosts:
      - "host.docker.internal:host-gateway"
      - "host.containers.internal:host-gateway"
    volumes:
      - /sys/fs/cgroup:/sys/fs/cgroup:rw
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
      - unifi-os-server-network
    depends_on:
      - unifi-os-server-mongodb
    environment:
      TZ: Europe/Amsterdam
      UOS_SYSTEM_IP: "127.0.0.1"
      # SSO bypass for the Network App (port 7443).  Used by UniHosted for
      # debugging and direct API access.  NOT for production — the port is
      # bound to localhost above and must stay that way.
      EXPOSE_NETWORK_APP: "true"

      MONGO_INTERNAL: "false" # Defaults to false → uses the external MongoDB service below.
      # Set to "true" and remove the unifi-network-mongodb service + depends_on
      # to let the UniFi Network App run its own mongod (port 27117).

  unifi-os-server-mongodb:
    container_name: unifi-os-server-mongodb
    image: mongo:4.4
    networks:
      - unifi-os-server-network
    volumes:
      - ./docker/mongodb:/data/db

networks:
  unifi-os-server-network:
```


## Why This Exists

Ubiquiti ships UOS as a Podman image because Podman is the container platform they happen to use. At UniHosted we were already running everything else in Docker, so rather than maintain a parallel Podman setup just for one application, we figured out how to convert that Podman image into a Docker image. Once the pipeline worked, it seemed silly not to share it. If you're in the same boat, here it is.

By default the internal mongod is removed and the container expects a separate MongoDB 4.4 instance (see the included `docker-compose.yaml`). Set `MONGO_INTERNAL=true` to let the UniFi Network App manage its own bundled mongod (port 27117) instead.

## How It Works

One of the nice things about this project is that the build is fully transparent: nothing happens behind a curtain. We download the official Ubiquiti UOS installer, extract the embedded Podman image (which is already in OCI format), and flatten its layers into a rootfs that Docker can use. In other words, we're not distributing or re-distributing any Ubiquiti code; we're converting an image from one container format to another. Our own entrypoint is layered on top, and at runtime it configures MongoDB, wires up networking (macvlan `eth0` alias), exposes PostgreSQL, and hands off to systemd. The entire pipeline runs through the [`build-image`](.github/workflows/build-image.yml) GitHub Action, so you can inspect exactly what happens at every step.

---

This project is not affiliated with, endorsed by, or supported by Ubiquiti Inc. All trademarks and copyrights belong to their respective owners.
