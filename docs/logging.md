# Container logging

[Back to the README](../README.md)

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
Text output escapes terminal control characters (for example, ESC becomes
`\u001b`) to prevent messages from changing the terminal display. Both formats
limit each incoming journal/file/reader-error record to 1 MiB. Larger records are
dropped in full with a warning, and collection resumes at the next newline.
This bounds buffering even when a service writes a long unterminated line.

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
  Other service units retain their names without `.service`. Messages from the
  root system manager (PID 1 in `init.scope`) about these services use the target
  service name and expose `related_unit`; the original systemd emitter remains
  in `journal`.
- **Context:** journal timestamps retain microseconds and UTC timezone. `unit`,
  `identifier`, `process`, and `pid` are exposed when available. An allowlist under
  `journal` retains the original message and priority, identifier, cursor,
  timestamps, boot and invocation IDs, transport, system/user units, PID/UID/GID,
  process name and executable path. Command lines and arbitrary additional
  journal fields are excluded. Message content and application attributes are
  not secret-redacted; applications should avoid logging credentials.
  Long fields are requested with `journalctl --all`; multiline journal messages stay in one JSON record
  with escaped newlines. Binary/repeated fields retain their original arrays in
  `journal`. Kernel, host networking, and unrelated system services are excluded.
- **Parsing:** journal priority supplies the default level. Recognized Network,
  Logback, Node error, and MongoDB messages add application severity and available
  logger/thread/component fields. Parsing never lowers a journal warning/error
  severity. MongoDB JSON is parsed only for MongoDB service units or a journal
  executable path ending in `/mongod` within `unifi.service`; the systemd service
  label is preserved, including `unifi-network` for bundled MongoDB. Its original
  JSON stays in `journal.MESSAGE`; structured attributes deeper than 16 levels
  are replaced with a depth-limit marker. Unknown
  formats remain visible. PostgreSQL records expose PID, connection context,
  severity, and the original timestamp. UTC/numeric offsets are normalized;
  ambiguous timezone abbreviations use collection time while retaining the
  original timestamp. `DETAIL`, `HINT`, `CONTEXT`, and `STATEMENT` are retained as
  `postgres_severity`, with `level: "unknown"` rather than guessing a severity.
- **Service scope:** includes UniFi/UOS/ULP/UCS services and their PostgreSQL,
  MongoDB, RabbitMQ, and nginx dependencies. Routine MongoDB connection, client
  metadata, and successful-authentication messages at info/debug/notice levels
  are suppressed only for those identified MongoDB emitters; warnings, errors,
  and other diagnostics remain. Records without recognized system service
  attribution are excluded; application-supplied identifiers cannot opt in.
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
