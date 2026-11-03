'use strict';

const { spawn } = require('node:child_process');
const { readdir } = require('node:fs/promises');
const { setTimeout: sleep } = require('node:timers/promises');

const SCHEMA = 'uos.v1';
const LEVELS = ['emergency', 'alert', 'critical', 'error', 'warning', 'notice', 'info', 'debug'];
const PG_LOG = '/var/log/postgresql/postgresql-14-main.log';
const UNIFI_UNIT = /^(?:(?:unifi|uos|ulp|ucs)(?:-[\w.@-]+)?|uid-agent|postgresql(?:-cluster)?(?:@[\w.-]+)?|mongod(?:b)?|rabbitmq-server|nginx)\.service$/;

function relatedUnit(record) {
    if (field(record.SYSLOG_IDENTIFIER) !== 'systemd' && field(record._COMM) !== 'systemd') return undefined;
    const unit = field(record.UNIT) || field(record.OBJECT_SYSTEMD_UNIT) || field(record.USER_UNIT);
    return unit && UNIFI_UNIT.test(unit) ? unit : undefined;
}

function shouldForwardJournal(record) {
    if (field(record._TRANSPORT) === 'kernel') return false;
    const unit = field(record._SYSTEMD_USER_UNIT) || field(record._SYSTEMD_UNIT);
    if (unit && UNIFI_UNIT.test(unit)) return true;
    if (relatedUnit(record)) return true;
    // Some syslog emitters have no cgroup attribution. Only accept known daemons.
    return !unit && /^(?:postgres(?:ql)?(?:@[\w.-]+)?|mongod(?:b)?|nginx|rabbitmq-server|unifi(?:-[\w.-]+)?)$/.test(field(record.SYSLOG_IDENTIFIER) || '');
}

function shouldForwardEvent(event) {
    // Keep warnings/errors about connections and authentication. Only routine
    // MongoDB lifecycle messages are suppressed, not arbitrary connection text.
    return !(event.service === 'mongodb' && ['info', 'debug', 'trace', 'notice'].includes(event.level)
        && /^(?:Connection accepted|Connection ended|Authentication succeeded|client metadata|Successfully authenticated)(?::| |$)/.test(event.message));
}

function field(value) {
    if (Array.isArray(value)) {
        // journalctl represents binary values as byte arrays and repeated fields
        // as arrays of values. The original representation stays in .journal.
        if (value.every(Number.isInteger)) return Buffer.from(value).toString('utf8');
        return field(value[0]);
    }
    return typeof value === 'string' ? value : undefined;
}

function timestamp(microseconds) {
    if (!/^\d+$/.test(microseconds || '')) return undefined;
    const value = BigInt(microseconds);
    const date = new Date(Number(value / 1000n));
    if (!Number.isFinite(date.getTime())) return undefined;
    return date.toISOString().replace(/\.\d{3}Z$/, `.${String(value % 1000000n).padStart(6, '0')}Z`);
}

function serviceName(unit, identifier, processName) {
    // Trusted systemd attribution wins over generic executables such as node/java.
    const name = (unit?.endsWith('.service') ? unit : undefined) || identifier || processName || unit || 'unknown';
    if (/^postgres(?:ql)?(?:@|\b)/.test(name)) return 'postgresql';
    if (/^(?:mongo(?:db|d))(?:\b)/.test(name)) return 'mongodb';
    if (/^unifi(?:\.service)?$/.test(name)) return 'unifi-network';
    return name.replace(/\.service$/, '');
}

function levelName(level) {
    const name = level.toLowerCase();
    return ({ warn: 'warning', log: 'info', panic: 'critical', debug1: 'debug',
        debug2: 'debug', debug3: 'debug', debug4: 'debug', debug5: 'debug' })[name] || name;
}

function parseMessage(event) {
    // Keep .message intact: prefixes and whitespace can be useful diagnostics.
    const message = event.message;
    const network = message.match(/^\[([^\]]+)\]\s+<([^>]+)>\s+(TRACE|DEBUG|INFO|WARN|ERROR)\s+(\S+)\s+-\s/s);
    const logback = message.match(/^\d{2}:\d{2}:\d{2},\d+\s+\|-(TRACE|DEBUG|INFO|WARN|ERROR)\s+in\s+(\S+)\s+-/);
    const severityPrefix = message.match(/^(TRACE|DEBUG|INFO|NOTICE|WARN|WARNING|ERROR|FATAL|CRITICAL|ALERT|EMERGENCY):/);
    if (network) {
        event.application_timestamp = network[1];
        event.thread = network[2];
        event.level = levelName(network[3]);
        event.logger = network[4];
    } else if (logback) {
        event.level = levelName(logback[1]);
        event.logger = logback[2];
    } else if (severityPrefix) {
        event.level = levelName(severityPrefix[1]);
    } else if (/^\s*(?:[\w.]*Error|ERROR|FATAL):/.test(message)) {
        event.level = /^\s*FATAL:/.test(message) ? 'fatal' : 'error';
    }
    try {
        const mongo = JSON.parse(message);
        if (mongo && typeof mongo.msg === 'string' && typeof mongo.t?.$date === 'string' && typeof mongo.s === 'string') {
            event.service = 'mongodb';
            event.message = mongo.msg;
            event.level = ({ I: 'info', W: 'warning', E: 'error', F: 'fatal' })[mongo.s]
                || (/^D/.test(mongo.s) ? 'debug' : event.level);
            event.component = mongo.c;
            event.thread = mongo.ctx;
            event.event_id = mongo.id;
            event.attributes = mongo.attr;
            event.application_timestamp = mongo.t.$date;
        }
    } catch {
        // Plain-text messages are expected; retain them unchanged.
    }
    return event;
}

function journalEvent(record) {
    const unit = field(record._SYSTEMD_USER_UNIT) || field(record._SYSTEMD_UNIT);
    const identifier = field(record.SYSLOG_IDENTIFIER);
    const processName = field(record._COMM);
    const priority = field(record.PRIORITY);
    const pid = field(record._PID) || field(record.SYSLOG_PID);
    const target = relatedUnit(record);
    return parseMessage({
        log_schema: SCHEMA,
        source: 'journal',
        timestamp: timestamp(field(record.__REALTIME_TIMESTAMP)) || new Date().toISOString(),
        service: serviceName(target || unit, identifier, processName),
        unit,
        related_unit: target,
        identifier,
        process: processName,
        pid: /^\d+$/.test(pid || '') ? Number(pid) : undefined,
        level: LEVELS[priority] || 'unknown',
        message: field(record.MESSAGE) ?? '',
        // Includes cursor, boot/invocation IDs, transport, original priority,
        // timestamps and any application fields, without an allowlist.
        journal: record,
    });
}

function postgresEvent(message, path = PG_LOG) {
    const event = {
        log_schema: SCHEMA, source: 'file', service: 'postgresql',
        unit: 'postgresql@14-main.service', file: path,
        timestamp: new Date().toISOString(), level: 'unknown', message,
    };
    // Debian's default: %m [%p] %q%u@%d, followed by PostgreSQL's severity.
    const match = message.match(/^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}(?:\.\d+)? \S+) \[(\d+)\] (.*?)\b(DEBUG[1-5]?|INFO|NOTICE|WARNING|ERROR|LOG|FATAL|PANIC|DETAIL|HINT|CONTEXT|STATEMENT):\s*/);
    if (match) {
        event.original_timestamp = match[1];
        event.pid = Number(match[2]);
        event.postgres_context = match[3].trim();
        event.postgres_severity = match[4];
        if (!['DETAIL', 'HINT', 'CONTEXT', 'STATEMENT'].includes(match[4])) {
            event.level = levelName(match[4]);
        }
        // Do not guess ambiguous abbreviations such as CST. Retain those and
        // use collection time; UTC and numeric offsets can be converted safely.
        const time = match[1].match(/^(\d{4}-\d{2}-\d{2}) (\d{2}:\d{2}:\d{2}(?:\.\d+)?) (UTC|GMT|[+-]\d{2}(?::?\d{2})?)$/);
        if (time) {
            let zone = time[3];
            if (zone === 'UTC' || zone === 'GMT') zone = 'Z';
            else if (zone.length === 3) zone += ':00';
            const date = new Date(`${time[1]}T${time[2]}${zone}`);
            if (Number.isFinite(date.getTime())) event.timestamp = date.toISOString();
        }
    }
    return event;
}

function diagnostic(message, level = 'info', service = 'uos-log-forwarder') {
    return { log_schema: SCHEMA, timestamp: new Date().toISOString(), service,
        source: service, level, message };
}

// Async iteration propagates Docker stdout backpressure to journalctl/tail.
// No line-size limit or JSON truncation; newlines in MESSAGE remain escaped in
// a single output record. Invalid input is emitted rather than discarded.
async function* lines(stream) {
    stream.setEncoding('utf8');
    let pending = '';
    for await (const chunk of stream) {
        pending += chunk;
        let newline;
        while ((newline = pending.indexOf('\n')) !== -1) {
            const line = pending.slice(0, newline);
            pending = pending.slice(newline + 1);
            yield line;
        }
    }
    if (pending) yield pending;
}

function emit(event) {
    return new Promise((resolve, reject) => {
        process.stdout.write(`${JSON.stringify(event)}\n`, error => error ? reject(error) : resolve());
    });
}

async function journalFilesExist(roots = ['/run/log/journal', '/var/log/journal']) {
    for (const root of roots) {
        let entries;
        try {
            entries = await readdir(root, { withFileTypes: true });
        } catch (error) {
            if (error.code === 'ENOENT') continue;
            throw error;
        }
        if (entries.some(entry => entry.isFile() && entry.name.endsWith('.journal'))) return true;
        for (const entry of entries.filter(entry => entry.isDirectory())) {
            try {
                const files = await readdir(`${root}/${entry.name}`);
                if (files.some(file => file.endsWith('.journal'))) return true;
            } catch (error) {
                if (error.code !== 'ENOENT') throw error;
            }
        }
    }
    return false;
}

async function forward({ since = `@${Math.floor(Date.now() / 1000)}`, postgresLog = PG_LOG,
    journalReady = journalFilesExist } = {}) {
    let stopping = false;
    let cursor;
    const children = new Set();
    const stop = () => {
        stopping = true;
        for (const child of children) child.kill('SIGTERM');
    };
    process.once('SIGTERM', stop);
    process.once('SIGINT', stop);

    async function run(command, args, handle) {
        const child = spawn(command, args, { stdio: ['ignore', 'pipe', 'pipe'], env: { ...process.env, LC_ALL: 'C' } });
        children.add(child);
        // Attach error handling immediately, including ENOENT at spawn time.
        const exited = new Promise(resolve => {
            child.once('error', error => resolve(error.message));
            child.once('exit', (code, signal) => resolve(signal || code));
        });
        try {
            await Promise.all([
                (async () => { for await (const line of lines(child.stdout)) await handle(line); })(),
                (async () => {
                    for await (const line of lines(child.stderr)) {
                        await emit({ ...diagnostic(line, 'warning'), reader: command });
                    }
                })(),
            ]);
            const status = await exited;
            if (!stopping) await emit(diagnostic(`${command} exited (${status}); retrying in 1s`, 'warning'));
        } finally {
            child.kill('SIGTERM');
            children.delete(child);
        }
    }

    try {
        await Promise.all([
            (async () => {
                while (!stopping) {
                    // systemd 247 can stay alive without noticing a journal
                    // directory created after --follow started. Wait for a file,
                    // then replay startup records using the original boundary.
                    if (!await journalReady()) {
                        await sleep(1000);
                        continue;
                    }
                    // --all avoids journalctl's JSON null substitution for long
                    // fields. --no-tail includes every record since this start.
                    const args = ['--follow', '--no-tail', '--no-pager', '--quiet', '--all', '--output=json',
                        cursor ? `--after-cursor=${cursor}` : `--since=${since}`];
                    const previousCursor = cursor;
                    await run('journalctl', args, async line => {
                        let record;
                        try {
                            record = JSON.parse(line);
                            if (!record || typeof record !== 'object' || Array.isArray(record)) throw new Error('not an object');
                        } catch {
                            await emit(diagnostic(`Unparsed journal output: ${line}`, 'warning'));
                            return;
                        }
                        const event = journalEvent(record);
                        if (shouldForwardJournal(record) && shouldForwardEvent(event)) await emit(event);
                        // Advance over excluded records too, so reconnecting does
                        // not repeatedly scan host/kernel traffic.
                        cursor = field(record.__CURSOR) || cursor;
                    });
                    if (!stopping && cursor && cursor === previousCursor) {
                        // A vacuumed/invalid cursor must not trap us in an
                        // endless failing seek. Replay retained startup history.
                        await emit(diagnostic('Journal reader made no progress; retrying from container start', 'warning'));
                        cursor = undefined;
                    }
                    if (!stopping) await sleep(1000);
                }
            })(),
            (async () => {
                while (!stopping) {
                    // Replay the current file, including startup failures that
                    // happened before tail opened it. No ten-line tail limit.
                    await run('tail', ['--lines', '+1', '--follow=name', '--retry', '--quiet',
                        '--sleep-interval=0.2', '--max-unchanged-stats=1', postgresLog],
                    line => emit(postgresEvent(line, postgresLog)));
                    // If tail itself fails, replay rather than silently lose
                    // records written while it was down (duplicates possible).
                    if (!stopping) await sleep(1000);
                }
            })(),
        ]);
    } finally {
        stop();
        process.removeListener('SIGTERM', stop);
        process.removeListener('SIGINT', stop);
    }
}

module.exports = { journalEvent, postgresEvent, diagnostic, lines, journalFilesExist, shouldForwardJournal, shouldForwardEvent, forward };

if (require.main === module) {
    if (process.argv[2] === '--entrypoint') {
        const message = process.argv[3] || '';
        const level = /^ERROR:/.test(message) ? 'error' : /^WARNING:/.test(message) ? 'warning' : 'info';
        emit(diagnostic(message, level, 'uos-entrypoint')).catch(() => { process.exitCode = 1; });
    } else {
        forward({ since: process.argv[2] }).catch(error => {
            process.stderr.write(`uos-log-forwarder: ${error.stack}\n`);
            process.exitCode = 1;
        });
    }
}
