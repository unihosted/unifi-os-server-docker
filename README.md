# UniFi OS Server in Docker

> Ubiquiti only ships the UniFi OS Server (UOS) as an OCI image embedded inside a proprietary Rust installer — you can't just pull it from a registry. This repository extracts that OCI image, adjusts it to our liking, and ships it with a compose file and config that make it fit to run in Docker. No parallel Podman setup required.

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
      - /var/log/journal
      - /var/opt/unifi/tmp:size=64m
      - /data/unifi-core/config/http
    networks:
      - unifi-os-server-network
    depends_on:
      - unifi-os-server-mongodb
    environment:
      TZ: Europe/Amsterdam
      UOS_SYSTEM_IP: "127.0.0.1"
      UOS_LOG_FORMAT: "text" # Default; set to "json" for structured log collectors.
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

Ubiquiti ships UOS as an OCI image, but bundles it inside a proprietary installer rather than publishing it to a registry. At UniHosted we were already running everything else in Docker, so rather than maintain a parallel Podman setup just for one application, we extract the OCI image from the installer and re-package it so it runs cleanly under Docker. Once the pipeline worked, it seemed silly not to share it. If you're in the same boat, here it is.

By default the internal mongod is removed and the container expects a separate MongoDB 4.4 instance (see the included `docker-compose.yaml`). Set `MONGO_INTERNAL=true` to let the UniFi Network App manage its own bundled mongod (port 27117) instead.

## How It Works

One of the nice things about this project is that the build is fully transparent: nothing happens behind a curtain. We download the official Ubiquiti UOS installer, extract the embedded OCI image from it, and flatten its layers into a rootfs that Docker can consume. In other words, we're not distributing or re-distributing any Ubiquiti code; we're taking an OCI image that Ubiquiti already built and making it runnable outside their installer. Our own entrypoint is layered on top, and at runtime it configures MongoDB, wires up networking (macvlan `eth0` alias), exposes PostgreSQL, and hands off to systemd. The entire pipeline runs through the [`build-image`](.github/workflows/build-image.yml) GitHub Action, so you can inspect exactly what happens at every step.

## Rebuilding all supported versions

Every version uses the same Dockerfile, entrypoint, and log forwarder. The
`build-image` workflow defaults to `uos_server_version: all`, rebuilding 4.3.6,
5.0.6, 5.1.15, 5.1.19, 5.1.21, 5.1.37, 5.1.40, and 5.1.42 from the selected Git
ref. All have amd64 and arm64 builds except 4.3.6, which has only amd64.
Older releases that only bundle Node 22 receive Node 24 for the forwarder; their
application runtime stays unchanged.

Set `push` to `false` for a build without publishing. When publishing all versions,
each version gets its own image tag and `latest` points to the newest selected
version (currently 5.1.42). Existing registry images gain these changes only after
a rebuild and publish. You can still select one version or build a release tag;
custom installer URLs require a single explicit version.

## Container logs

This image runs many services, including UniFi Core, UniFi Network, PostgreSQL,
nginx, and RabbitMQ. Each produces its own log format, so the forwarder identifies
the service and parses timestamps and severity into a consistent output. This
makes it easier to see which service a message belongs to and spot errors in
`docker logs`.

Human-readable text is the default (`UOS_LOG_FORMAT=text`). View it with
`docker logs -f unifi-os-server`:

```text
2026-11-03T07:24:15.277999Z [postgresql] INFO: Started PostgreSQL Cluster 14-main.
2026-11-03T07:24:15.308Z [uos-entrypoint] INFO: PostgreSQL: exposed on port 5432
```

For structured log collectors, opt into JSON in your Compose environment:

```yaml
environment:
  UOS_LOG_FORMAT: "json"
```

Recreate the container after changing the setting (`docker compose up -d`).

Both formats use the same service filtering, severity parsing, and recovery.
Text mode prints the timestamp, service, level, and message, with the same prefix
on every line of a multiline message. JSON mode also includes the structured
metadata described below. Invalid format values stop startup with an error.

In JSON mode, the image emits newline-delimited JSON to Docker stdout. Each record has
`log_schema: "uos.v1"`, `timestamp`, `service`, `source`, `level`, and `message`.
This replaces the old `[uos-entrypoint]` and abbreviated journal text formats.
Log collectors must decode the JSON to use these fields.

```json
{"log_schema":"uos.v1","source":"file","service":"postgresql","unit":"postgresql@14-main.service","file":"/var/log/postgresql/postgresql-14-main.log","timestamp":"2026-11-03T06:22:11.205Z","level":"error","message":"2026-11-03 06:22:11.205 UTC [456] app@db ERROR:  division by zero","original_timestamp":"2026-11-03 06:22:11.205 UTC","pid":456,"postgres_context":"app@db","postgres_severity":"ERROR"}
```

- **Journal:** forwards UniFi service records since container startup, then follows
  new entries. Service names come from systemd units, so `node24` from
  `unifi-core.service` is labeled `unifi-core`, and `unifi.service` is
  `unifi-network`. PostgreSQL and MongoDB use `postgresql` and `mongodb`.
  Other service units retain their names without `.service`. Systemd messages about these services use the target service name and expose
  `related_unit`; the original systemd emitter remains in `journal`.
- **Context:** journal timestamps retain microseconds and UTC timezone. `unit`,
  `identifier`, `process`, and `pid` are exposed when available. The complete
  original record stays under `journal`, including priority, cursor, boot and
  invocation IDs, transport, and application fields. Long fields are requested
  with `journalctl --all`; multiline journal messages stay in one JSON record
  with escaped newlines. Binary/repeated fields retain their original arrays in
  `journal`. Kernel, host networking, and unrelated system services are excluded.
- **Parsing:** journal priority supplies the default level. Recognized Network,
  Logback, Node error, and MongoDB messages add application severity and available
  logger/thread/component fields. MongoDB exposes its message text, with the
  original JSON retained in `journal.MESSAGE`. Unknown
  formats remain visible. PostgreSQL records expose PID, connection context,
  severity, and the original timestamp. UTC/numeric offsets are normalized;
  ambiguous timezone abbreviations use collection time while retaining the
  original timestamp. `DETAIL`, `HINT`, `CONTEXT`, and `STATEMENT` are retained as
  `postgres_severity`, with `level: "unknown"` rather than guessing a severity.
- **Service scope:** includes UniFi/UOS/ULP/UCS services and their PostgreSQL,
  MongoDB, RabbitMQ, and nginx dependencies. Routine MongoDB connection, client
  metadata, and successful-authentication messages at info/debug/notice levels
  are suppressed; warnings, errors, and other diagnostics remain.
- **PostgreSQL file:** also follows the bundled cluster's
  `/var/log/postgresql/postgresql-14-main.log`, including delayed creation,
  rename-and-create rotation, and detected truncation. The current file is read
  from the beginning on startup, so a container restart can replay retained
  PostgreSQL logs. Each physical file line is a record, including SQL continuation
  lines. Custom PostgreSQL log paths and other application log files are not
  collected by this forwarder; they need a separate file source.
- **Recovery:** failed journal readers restart after the last emitted cursor,
  falling back to startup history if that reader exits without making progress;
  failed file readers replay the current file. If the forwarder itself crashes,
  the entrypoint restarts it and replays available records since container start.
  Replays can produce duplicates. Backpressure pauses readers instead of dropping
  output. There is no durable delivery queue: journal/file retention and Docker's
  logging driver still determine how much history survives outages.

These behaviors use systemd's [JSON output options](https://www.freedesktop.org/software/systemd/man/latest/journalctl.html)
and [journal fields](https://www.freedesktop.org/software/systemd/man/latest/systemd.journal-fields.html).

For a readable local view while keeping the container in JSON mode:

```sh
docker logs -f unifi-os-server | jq -r '[.timestamp, .service, .level, .message] | @tsv'
```

For Vector's `docker_logs` source, decode recognized image records **before** any
legacy text parsing. For example, use this in a remap transform and put existing
legacy parsing in the `else` branch. This preserves Docker container metadata and
leaves sidecar formats to their existing parsers:

```text
parsed, err = parse_json(.message)
if err == null && is_object(parsed) && parsed.log_schema == "uos.v1" {
  . = merge(., object!(parsed))
  .timestamp = parse_timestamp!(string!(parsed.timestamp), "%+")
  .parse_status = "parsed"
} else {
  # Existing legacy / sidecar parsing goes here.
}
```

## Node.js security patch

The image replaces Ubiquiti's `/usr/bin/node24` with the official Node.js **24.22.1** binary on amd64 and arm64 to address [Node2Shell (CVE-2026-111497)](https://nodejs.org/en/blog/release/v24.22.1/). This is the executable used by UniFi Core's systemd service. Downloads are checked against pinned SHA-256 hashes, and the build verifies the version, native addon ABI, and Brotli compression/decompression inside the extracted rootfs.

This is a temporary runtime override until Ubiquiti ships a fixed package. The Debian `node24` package metadata still reports Ubiquiti's original version; check the running binary with `docker exec unifi-os-server /usr/bin/node24 --version`. An in-container package update can overwrite the patched binary, so deploy rebuilt images to retain the fix. When updating the patch, change the version and both architecture hashes together in `Dockerfile`.

---

This project is not affiliated with, endorsed by, or supported by Ubiquiti Inc. All trademarks and copyrights belong to their respective owners.
