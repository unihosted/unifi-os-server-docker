'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const { Readable } = require('node:stream');
const { journalEvent, postgresEvent, lines } = require('../uos-logs.cjs');

const base = {
    __REALTIME_TIMESTAMP: '1793686931205123', __CURSOR: 'cursor-1',
    _BOOT_ID: 'boot-1', _SYSTEMD_INVOCATION_ID: 'invocation-1',
    _SYSTEMD_UNIT: 'unifi-core.service', _COMM: 'node24', _PID: '123',
    SYSLOG_IDENTIFIER: 'node24', PRIORITY: '6', MESSAGE: 'Started',
};

test('journal metadata survives with microsecond timestamp and service attribution', () => {
    const event = journalEvent(base);
    assert.equal(event.timestamp, '2026-11-03T06:22:11.205123Z');
    assert.equal(event.service, 'unifi-core');
    assert.equal(event.unit, 'unifi-core.service');
    assert.equal(event.process, 'node24');
    assert.equal(event.pid, 123);
    assert.equal(event.level, 'info');
    assert.deepEqual(event.journal, base);
});

test('long, multiline and binary messages survive a JSON round trip', () => {
    const message = 'Failure\n\tat worker.run()\n' + 'x'.repeat(100000);
    const event = journalEvent({ ...base, MESSAGE: message });
    const serialized = JSON.stringify(event);
    assert.equal(serialized.split('\n').length, 1);
    assert.equal(JSON.parse(serialized).message, message);
    const bytes = [...Buffer.from('binary\u0000diagnostic é')];
    const binary = journalEvent({ ...base, MESSAGE: bytes });
    assert.equal(binary.message, 'binary\u0000diagnostic é');
    assert.deepEqual(binary.journal.MESSAGE, bytes);
});

test('repeated fields, invalid timestamps and unknown units do not drop records', () => {
    const event = journalEvent({ MESSAGE: ['first', 'second'], PRIORITY: ['3', '4'],
        __REALTIME_TIMESTAMP: 'bad', EXTRA: ['a', 'b'] });
    assert.equal(event.service, 'unknown');
    assert.equal(event.message, 'first');
    assert.equal(event.level, 'error');
    assert.deepEqual(event.journal.MESSAGE, ['first', 'second']);
    assert.ok(Number.isFinite(Date.parse(event.timestamp)));
    assert.equal(journalEvent({ __REALTIME_TIMESTAMP: '9'.repeat(30) }).service, 'unknown');
});

test('service aliases and systemd target units do not misattribute the emitter', () => {
    for (const [unit, service] of [['postgresql@14-main.service', 'postgresql'],
        ['unifi.service', 'unifi-network'], ['nginx.service', 'nginx'],
        ['mongod.service', 'mongodb'], ['ulp-go.service', 'ulp-go']]) {
        assert.equal(journalEvent({ ...base, _SYSTEMD_UNIT: unit }).service, service);
    }
    assert.equal(journalEvent({ _SYSTEMD_UNIT: 'init.scope', SYSLOG_IDENTIFIER: 'systemd',
        UNIT: 'postgresql@14-main.service', MESSAGE: 'Started PostgreSQL' }).service, 'postgresql');
    assert.equal(journalEvent({ SYSLOG_IDENTIFIER: 'kernel', PRIORITY: '2' }).service, 'kernel');
});

test('application severity overrides stdout priority without removing message context', () => {
    const message = '[2026-11-03T06:22:11,205Z] <worker> WARN system - Failure\n\tat worker.run()';
    const event = journalEvent({ ...base, _SYSTEMD_UNIT: 'unifi.service', MESSAGE: message });
    assert.equal(event.level, 'warning');
    assert.equal(event.logger, 'system');
    assert.equal(event.thread, 'worker');
    assert.equal(event.message, message);
    assert.equal(event.journal.PRIORITY, '6');
    assert.equal(journalEvent({ ...base, MESSAGE: 'WARNING: restricted native method' }).level, 'warning');
    assert.equal(journalEvent({ ...base, MESSAGE: '07:04:05,123 |-ERROR in example.Logger - Failed' }).level, 'error');
    assert.equal(journalEvent({ ...base, MESSAGE: '  TypeError: bad input\nstack' }).level, 'error');
});

test('MongoDB JSON exposes database fields and retains the original JSON', () => {
    const message = JSON.stringify({ t: { $date: '2026-11-03T06:22:11.205Z' },
        s: 'W', c: 'STORAGE', ctx: 'worker', id: 123, msg: 'Checkpoint', attr: { durationMillis: 100 } });
    const event = journalEvent({ ...base, MESSAGE: message });
    assert.equal(event.service, 'mongodb');
    assert.equal(event.level, 'warning');
    assert.equal(event.component, 'STORAGE');
    assert.equal(event.event_id, 123);
    assert.deepEqual(event.attributes, { durationMillis: 100 });
    assert.equal(event.message, 'Checkpoint');
    assert.equal(event.journal.MESSAGE, message);
});

test('PostgreSQL extracts severity, PID, timestamp and connection context losslessly', () => {
    const message = '2026-11-03 07:22:11.205 +01 [456] user@database ERROR:  relation does not exist';
    const event = postgresEvent(message);
    assert.equal(event.service, 'postgresql');
    assert.equal(event.timestamp, '2026-11-03T06:22:11.205Z');
    assert.equal(event.level, 'error');
    assert.equal(event.pid, 456);
    assert.equal(event.postgres_context, 'user@database');
    assert.equal(event.message, message);
    assert.equal(postgresEvent('2026-11-03 06:22:11.205 UTC [456] LOG:  ready').level, 'info');
    const detail = postgresEvent('2026-11-03 06:22:11.205 UTC [456] user@db DETAIL:  more context');
    assert.equal(detail.postgres_severity, 'DETAIL');
    assert.equal(detail.level, 'unknown');
});

test('unknown PostgreSQL formats, continuations and ambiguous zones remain visible', () => {
    assert.equal(postgresEvent('\tSELECT broken;').message, '\tSELECT broken;');
    const event = postgresEvent('2026-11-03 06:22:11.205 CST [1] FATAL:  failed');
    assert.equal(event.original_timestamp, '2026-11-03 06:22:11.205 CST');
    assert.equal(event.level, 'fatal');
    assert.equal(event.timestamp.endsWith('Z'), true);
});

test('stream framing handles fragmented UTF-8, blank lines and incomplete final lines', async () => {
    const content = Buffer.from('é\n\nlast');
    const result = [];
    for await (const line of lines(Readable.from([content.subarray(0, 1), content.subarray(1, 4), content.subarray(4)]))) {
        result.push(line);
    }
    assert.deepEqual(result, ['é', '', 'last']);
});

test('journal readiness waits for a real journal file in either storage layout', async t => {
    const { mkdtemp, mkdir, writeFile, rm } = require('node:fs/promises');
    const { tmpdir } = require('node:os');
    const path = require('node:path');
    const { journalFilesExist } = require('../uos-logs.cjs');
    const dir = await mkdtemp(path.join(tmpdir(), 'uos-journal-'));
    t.after(() => rm(dir, { recursive: true, force: true }));
    assert.equal(await journalFilesExist([path.join(dir, 'missing')]), false);
    assert.equal(await journalFilesExist([dir]), false);
    await mkdir(path.join(dir, 'machine-id'));
    assert.equal(await journalFilesExist([dir]), false);
    await writeFile(path.join(dir, 'machine-id', 'system.journal'), '');
    assert.equal(await journalFilesExist([dir]), true);
});


test('journal scope excludes kernel and host daemons but keeps UniFi dependencies and lifecycle failures', () => {
    const { shouldForwardJournal } = require('../uos-logs.cjs');
    assert.equal(shouldForwardJournal({ _TRANSPORT: 'kernel', SYSLOG_IDENTIFIER: 'kernel', MESSAGE: 'veth entered forwarding state' }), false);
    assert.equal(shouldForwardJournal({ _SYSTEMD_UNIT: 'ssh.service' }), false);
    assert.equal(shouldForwardJournal({ SYSLOG_IDENTIFIER: 'systemd', UNIT: 'docker.service' }), false);
    assert.equal(shouldForwardJournal({ SYSLOG_IDENTIFIER: 'systemd', UNIT: 'unifi-core.service', PRIORITY: '3' }), true);
    for (const unit of ['unifi.service', 'unifi-core.service', 'uos-agent.service', 'ulp-go.service', 'ucs-agent.service', 'uid-agent.service', 'postgresql@14-main.service', 'nginx.service', 'rabbitmq-server.service', 'mongodb.service']) {
        assert.equal(shouldForwardJournal({ _SYSTEMD_UNIT: unit }), true, unit);
    }
});

test('MongoDB routine connections are suppressed while errors and diagnostics remain', () => {
    const { shouldForwardEvent } = require('../uos-logs.cjs');
    for (const message of ['Connection accepted', 'Connection ended', 'Authentication succeeded', 'client metadata']) {
        assert.equal(shouldForwardEvent({ service: 'mongodb', level: 'info', message }), false);
        assert.equal(shouldForwardEvent({ service: 'mongodb', level: 'error', message }), true);
    }
    assert.equal(shouldForwardEvent({ service: 'mongodb', level: 'warning', message: 'Authentication failed' }), true);
    assert.equal(shouldForwardEvent({ service: 'mongodb', level: 'info', message: 'Checkpoint completed' }), true);
    assert.equal(shouldForwardEvent({ service: 'unifi-core', level: 'info', message: 'Connection accepted' }), true);
});
