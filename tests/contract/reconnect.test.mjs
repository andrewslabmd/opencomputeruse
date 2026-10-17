import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm, access } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawn } from 'node:child_process';
import { Host } from '../../packages/host/server.mjs';
import { Broker } from '../../packages/host/broker.mjs';
import { Client } from '../../packages/cli/client.mjs';
const root = new URL('../..', import.meta.url).pathname;
const sleep = ms => new Promise(r => setTimeout(r, ms));
class FakeBroker {
  calls = [];
  async call(name, args) { this.calls.push(name); if (this.block === name) return new Promise(() => {}); return { content: [{ type: 'text', text: name }] }; }
  async reset() {} async stop() {}
}
// Cleanup runs last-registered first, so hosts close before their directory goes.
function defer(t, fn) { if (!t.cleanups) { t.cleanups = []; t.after(async () => { for (const f of t.cleanups.reverse()) await f(); }); } t.cleanups.push(fn); }
async function directory(t) { const d = await mkdtemp(join(tmpdir(), 'ocu-restart-')); defer(t, () => rm(d, { recursive: true, force: true })); return d; }
async function host(dir, t, broker = new FakeBroker()) { const h = new Host({ directory: dir, broker }); await h.start(); defer(t, () => h.close().catch(() => {})); return h; }
const alive = pid => { try { process.kill(pid, 0); return true; } catch { return false; } };
async function exited(child) { if (child.exitCode !== null || child.signalCode) return; await new Promise(r => child.once('exit', r)); }
function deadPid() { const p = spawn('/usr/bin/true'); return new Promise(r => p.once('exit', () => r(p.pid))); }
// A host in its own process, without the app watchdog, as an app would leave it.
function hostProcess(dir, parentPid) {
  const script = `import { Host } from ${JSON.stringify(join(root, 'packages/host/server.mjs'))};
    await new Host({ directory: ${JSON.stringify(dir)}, broker: { async call() { return {}; }, async reset() {}, async stop() {} }, parentPid: ${parentPid} }).start(); process.stdout.write('ready\\n');`;
  const child = spawn(process.execPath, ['--input-type=module', '-e', script], { stdio: ['ignore', 'pipe', 'inherit'] });
  return new Promise((resolve, reject) => { child.stdout.once('data', () => resolve(child)); child.once('exit', c => reject(new Error(`host exited ${c}`))); });
}

test('client reconnects and registers again after the host restarts', async t => {
  const dir = await directory(t); const first = await host(dir, t);
  const client = await new Client(dir, { name: 'agent', reconnectMs: 5000 }).connect(); defer(t, () => client.close());
  await client.request('status'); await first.close();
  while (client.connected) await sleep(5);
  const second = await host(dir, t);
  const status = await client.request('status');
  assert.equal(status.pid, process.pid);
  assert.deepEqual(second.status().clients.map(c => c.name), ['agent']);
});

test('a request in flight when the host restarts fails once and is not replayed', async t => {
  const dir = await directory(t); const broker = new FakeBroker(); broker.block = 'use_observe';
  const first = await host(dir, t, broker);
  const client = await new Client(dir, { reconnectMs: 5000 }).connect(); defer(t, () => client.close());
  const pending = client.request('tools/call', { name: 'use_observe', arguments: { app_target: 'Fixture' } });
  while (!first.inflight) await sleep(5);
  const closing = first.close();
  await assert.rejects(pending, { code: 'host_disconnected', message: /not retried/ });
  await closing;
  const replacement = new FakeBroker(); await host(dir, t, replacement);
  const result = await client.request('tools/call', { name: 'use_permissions', arguments: {} });
  assert.equal(result.content[0].text, 'use_permissions');
  assert.deepEqual(broker.calls, ['use_observe']); assert.deepEqual(replacement.calls, ['use_permissions']);
  // The new host has no workflow: acting requires a fresh observation.
  await assert.rejects(client.request('tools/call', { name: 'use_action_batch', arguments: { actions: [{ kind: 'click', at: { x: 1, y: 1 } }] } }), { code: 'observation_required' });
});

test('a read-only request in flight when the host restarts is sent once more to the new host', async t => {
  const dir = await directory(t); const broker = new FakeBroker(); broker.block = 'use_permissions';
  const first = await host(dir, t, broker);
  const client = await new Client(dir, { reconnectMs: 5000 }).connect(); defer(t, () => client.close());
  const pending = client.request('tools/call', { name: 'use_permissions', arguments: {} });
  while (!broker.calls.length) await sleep(5);
  await first.close();
  const replacement = new FakeBroker(); await host(dir, t, replacement);
  assert.equal((await pending).content[0].text, 'use_permissions');
  assert.deepEqual(broker.calls, ['use_permissions']); assert.deepEqual(replacement.calls, ['use_permissions']);
});

test('a client revoked from the app does not reconnect by itself', async t => {
  const dir = await directory(t); const h = await host(dir, t);
  const a = await new Client(dir, { name: 'a', reconnectMs: 1000 }).connect(); const b = await new Client(dir, { name: 'b' }).connect();
  defer(t, () => { a.close(); b.close(); });
  const id = h.status().clients.find(c => c.name === 'a').id;
  await b.request('revoke', { client: id });
  while (a.connected) await sleep(5);
  await assert.rejects(a.request('status'), { code: 'revoked' });
  assert.deepEqual(h.status().clients.map(c => c.name), ['b']);
});

test('MCP adapter survives a host restart: the next tool call succeeds', async t => {
  const dir = await directory(t); const broker = new FakeBroker(); const first = await host(dir, t, broker);
  const mcp = new Broker(process.execPath, ['packages/cli/main.mjs', 'mcp'], { ...process.env, OCU_RUNTIME_DIR: dir });
  defer(t, () => mcp.stop());
  assert.equal((await mcp.call('computer_use_permissions', {})).content[0].text, 'use_permissions');
  broker.block = 'use_observe';
  const pending = mcp.call('computer_use_observe', { app_target: 'Fixture' });
  while (!first.inflight) await sleep(5);
  await first.close();
  const interrupted = await pending;
  assert.equal(interrupted.isError, true); assert.match(interrupted.content[0].text, /^host_disconnected: .*not retried/);
  const replacement = new FakeBroker(); const second = await host(dir, t, replacement);
  assert.equal((await mcp.call('computer_use_permissions', {})).content[0].text, 'use_permissions');
  assert.equal(JSON.parse((await mcp.call('computer_use_status', {})).content[0].text).pid, process.pid);
  assert.deepEqual(broker.calls, ['use_permissions', 'use_observe']); assert.deepEqual(replacement.calls, ['use_permissions']);
  assert.deepEqual(second.status().clients.map(c => c.name), ['MCP agent']);
});

test('startup stops a previous host whose app has exited and takes over', async t => {
  const dir = await directory(t);
  const stale = await hostProcess(dir, await deadPid()); defer(t, () => stale.kill('SIGKILL'));
  const h = await host(dir, t);
  await exited(stale); assert.equal(alive(stale.pid), false);
  const client = await new Client(dir).connect(); defer(t, () => client.close());
  assert.equal((await client.request('status')).pid, process.pid); assert.equal(h.status().pid, process.pid);
});

test('startup leaves a host whose app is alive and reports it clearly', async t => {
  const dir = await directory(t);
  const current = await hostProcess(dir, process.pid); defer(t, () => current.kill('SIGKILL'));
  await assert.rejects(new Host({ directory: dir, broker: new FakeBroker() }).start(), { code: 'already_running', message: new RegExp(`host ${current.pid} is already running for app process ${process.pid}`) });
  assert.equal(alive(current.pid), true);
});

test('a closing host releases its socket before native cleanup and never removes its replacement', async t => {
  const dir = await directory(t); const broker = new FakeBroker(); let finishCleanup;
  broker.stop = () => new Promise(r => { finishCleanup = r; });
  const old = await host(dir, t, broker);
  const closing = old.close();
  while (!finishCleanup) await sleep(5);
  const replacement = await host(dir, t);
  finishCleanup(); await closing;
  await access(join(dir, 'host.sock'));
  const client = await new Client(dir).connect(); defer(t, () => client.close());
  assert.equal(replacement.status().clients.length, 1);
});

test('the host process exits and releases its socket when its app dies', async t => {
  const dir = await directory(t);
  // The "app" spawns the real host entry point and reports its PID.
  const app = spawn(process.execPath, ['-e', `const c = require('node:child_process').spawn(process.execPath, [${JSON.stringify(join(root, 'packages/host/main.mjs'))}], { env: { ...process.env, OCU_RUNTIME_DIR: ${JSON.stringify(dir)}, OCU_PARENT_PID: String(process.pid) }, stdio: 'inherit' }); console.log(c.pid); setInterval(() => {}, 1000);`], { stdio: ['ignore', 'pipe', 'inherit'] });
  defer(t, () => app.kill('SIGKILL'));
  const hostPid = Number(await new Promise(r => app.stdout.once('data', r)));
  defer(t, () => { try { process.kill(hostPid, 'SIGKILL'); } catch {} });
  const client = new Client(dir, { reconnectMs: 5000 });
  for (let i = 0; i < 100; i++) { try { await client.connect('probe'); break; } catch { await sleep(50); } }
  assert.equal((await client.request('status')).pid, hostPid);
  await sleep(1500); assert.equal(alive(hostPid), true, 'host stays while its app is alive');
  client.close(); app.kill('SIGKILL');
  for (let i = 0; i < 100 && alive(hostPid); i++) await sleep(50);
  assert.equal(alive(hostPid), false);
  await assert.rejects(new Client(dir).connect(), { code: /ENOENT|ECONNREFUSED/ });
});
