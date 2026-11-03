#!/bin/bash
# Run only in a disposable image container, with this repository at /work.
set -euo pipefail

# Refuse to interfere with an already-running journal or database cluster.
test ! -S /run/systemd/journal/socket
test ! -d /etc/postgresql/14/logtest
mkdir -p /run/systemd/journal
FORWARDER_PID=""
JOURNAL_PID=""
cleanup() {
    if [ -n "$FORWARDER_PID" ]; then kill "$FORWARDER_PID" 2>/dev/null || true; fi
    if [ -n "$JOURNAL_PID" ]; then kill "$JOURNAL_PID" 2>/dev/null || true; fi
    pg_ctlcluster --skip-systemctl-redirect 14 logtest stop 2>/dev/null || true
}
trap cleanup EXIT

# Intentionally start before journald has created its directories/files.
/usr/bin/node24 -e 'require("/work/uos-logs.cjs").forward({postgresLog: "/tmp/postgresql.log"})' \
    >/tmp/forwarded.jsonl 2>/tmp/forwarder.err &
FORWARDER_PID=$!
sleep 1
/lib/systemd/systemd-journald >/tmp/journald.out 2>&1 &
JOURNAL_PID=$!
for _ in $(seq 1 50); do
    if [ -S /run/systemd/journal/dev-log ]; then break; fi
    sleep 0.1
done
logger -u /run/systemd/journal/dev-log -t postgres -p user.err 'uos real journal smoke test'
pg_createcluster 14 logtest --port=55432 --logfile=/tmp/postgresql.log --start >/tmp/pg-setup.out 2>&1
su postgres -s /bin/sh -c 'psql -p 55432 -c "select 1/0"' >/tmp/pg-query.out 2>&1 || true
for _ in $(seq 1 50); do
    if grep -q 'division by zero' /tmp/forwarded.jsonl && grep -q 'uos real journal smoke test' /tmp/forwarded.jsonl; then break; fi
    sleep 0.1
done
kill "$FORWARDER_PID"
wait "$FORWARDER_PID"
FORWARDER_PID=""
/usr/bin/node24 <<'JS'
const fs = require('node:fs');
const assert = require('node:assert/strict');
const logs = fs.readFileSync('/tmp/forwarded.jsonl', 'utf8').trim().split('\n').map(JSON.parse);
const journal = logs.find(e => e.message === 'uos real journal smoke test');
assert.ok(journal, 'real journal entry forwarded after journal appeared');
assert.equal(journal.service, 'postgresql');
assert.equal(journal.level, 'error');
assert.ok(journal.journal.__CURSOR);
const pg = logs.find(e => e.source === 'file' && e.message.includes('division by zero'));
assert.ok(pg, 'real PostgreSQL query error forwarded from file');
assert.equal(pg.level, 'error');
assert.ok(pg.pid > 0);
assert.equal(fs.readFileSync('/tmp/forwarder.err', 'utf8'), '');
console.log('PASS: delayed journald startup and real PostgreSQL query error');
JS
