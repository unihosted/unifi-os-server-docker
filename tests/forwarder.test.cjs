'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const { mkdtemp, writeFile, appendFile, rename, rm } = require('node:fs/promises');
const { tmpdir } = require('node:os');
const path = require('node:path');
const { setTimeout: sleep } = require('node:timers/promises');

async function until(predicate, description) {
    const deadline = Date.now() + 8000;
    while (!predicate()) {
        if (Date.now() > deadline) throw new Error(`Timed out: ${description}`);
        await sleep(20);
    }
}

test('reader restart, startup replay, missing files, rotation, truncation and shutdown', {
    skip: process.platform !== 'linux' && 'Requires GNU tail (run in the image or Linux CI)', timeout: 30000,
}, async t => {
    const dir = await mkdtemp(path.join(tmpdir(), 'uos-logs-'));
    const pg = path.join(dir, 'postgresql.log');
    const fixture = path.join(dir, 'journal.cjs');
    await writeFile(fixture, `
const fs = require('node:fs');
const state = ${JSON.stringify(path.join(dir, 'started'))};
const attempt = fs.existsSync(state) ? Number(fs.readFileSync(state, 'utf8')) : 0;
const args = process.argv.slice(2);
if (!args.includes('--all') || !args.includes('--no-tail') || !args.includes('--output=json')) process.exit(3);
if (attempt === 1 && !args.includes('--after-cursor=cursor-24')) process.exit(4);
if (attempt === 2 && !args.includes('--after-cursor=cursor-25')) process.exit(4);
if ((attempt === 0 || attempt === 3) && !args.includes('--since=@1793686900')) process.exit(5);
fs.writeFileSync(state, String(attempt + 1));
if (attempt === 2) process.exit(1); // Simulate a cursor that can no longer be sought.
for (let i = attempt === 0 ? 0 : attempt === 1 ? 25 : 26; i < (attempt === 0 ? 25 : attempt === 1 ? 26 : 27); i++) {
    console.log(JSON.stringify({ __CURSOR: 'cursor-' + i, __REALTIME_TIMESTAMP: '1793686931205123',
        _SYSTEMD_UNIT: 'unifi-core.service', _COMM: 'node24', PRIORITY: '6', _TRANSPORT: i === 24 ? 'kernel' : 'stdout',
        MESSAGE: 'record-' + i + (i === 0 ? '\\nstack\\n' + 'x'.repeat(100000) : '') }));
}
if (attempt === 0) { console.log('malformed journal output'); process.exitCode = 1; }
else if (attempt === 1) process.exitCode = 1;
else setInterval(() => {}, 1000);
`);
    await writeFile(path.join(dir, 'journalctl'), `#!/bin/sh\nexec '${process.execPath}' '${fixture}' "$@"\n`, { mode: 0o755 });
    const script = `require(${JSON.stringify(path.resolve(__dirname, '../uos-logs.cjs'))}).forward({ since: '@1793686900', postgresLog: ${JSON.stringify(pg)}, journalReady: async () => true }).catch(e => { console.error(e); process.exitCode = 1; })`;
    const child = spawn(process.execPath, ['-e', script], { env: { ...process.env, PATH: `${dir}:${process.env.PATH}` } });
    let exited = false;
    const done = new Promise(resolve => child.once('exit', (code, signal) => { exited = true; resolve({ code, signal }); }));
    t.after(async () => {
        if (!exited) child.kill('SIGKILL');
        await done;
        await rm(dir, { recursive: true, force: true });
    });
    let stderr = '';
    child.stderr.on('data', chunk => { stderr += chunk; });
    // Leave stdout unread initially, forcing the 100 KB record through pipe
    // backpressure before attaching the consumer.
    await sleep(300);
    const events = [];
    let pending = '';
    child.stdout.setEncoding('utf8');
    child.stdout.on('data', chunk => {
        pending += chunk;
        let newline;
        while ((newline = pending.indexOf('\n')) >= 0) {
            events.push(JSON.parse(pending.slice(0, newline)));
            pending = pending.slice(newline + 1);
        }
    });
    await until(() => events.some(e => e.message === 'record-26'), 'journal restart resumes after cursor and recovers from invalid cursor');
    const journal = events.filter(e => e.source === 'journal');
    assert.equal(journal.length, 26);
    assert.ok(journal.every(e => e.journal._TRANSPORT !== "kernel"));
    assert.equal(journal[0].message, 'record-0\nstack\n' + 'x'.repeat(100000));
    assert.ok(events.some(e => e.message.includes('malformed journal output')));

    const first = '2026-11-03 06:22:11.205 UTC [42] app@db ERROR:  first';
    await writeFile(pg, first + '\n');
    await until(() => events.some(e => e.message === first), 'file created after forwarder start');
    await appendFile(pg, '  SQL continuation\n');
    await until(() => events.some(e => e.message === '  SQL continuation'), 'continuation is retained');
    await rename(pg, pg + '.1');
    await writeFile(pg, 'rotated\n');
    await until(() => events.some(e => e.message === 'rotated'), 'rename-and-create rotation');
    await writeFile(pg, 'short\n');
    await until(() => events.some(e => e.message === 'short'), 'copytruncate rotation');
    assert.ok(events.filter(e => e.source === 'file').every(e => e.service === 'postgresql' && e.file === pg));

    child.kill('SIGTERM');
    await until(() => exited, 'graceful shutdown');
    assert.deepEqual(await done, { code: 0, signal: null });
    assert.equal(stderr, '');
    assert.equal(pending, '');
});
