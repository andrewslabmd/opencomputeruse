import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm, writeFile, readFile, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Host } from '../../packages/host/server.mjs';
import { Client } from '../../packages/cli/client.mjs';
// Observed apps get a stable fake pid, reported the way the engine reports it.
const pids = { Fixture: 101, Other: 202 };
const pidOf = target => pids[target] ?? 300 + target.length;
class FakeBroker {
  resets = 0; stops = 0; calls = [];
  async list() { return { tools: [] }; }
  async resolveApplication(target) { return pidOf(target); }
  async listApplications() { this.calls.push(['use_list_apps']); return { content: [{ type: 'text', text: 'apps' }] }; }
  async call(name, args) { this.calls.push([name, args]); if (this.block && name !== 'use_permissions') return new Promise((resolve, reject) => { this.reject = reject; }); if (args?.app_target) this.pid = pidOf(args.app_target); return { content: [{ type: 'text', text: name }], ...(this.pid && name !== 'use_permissions' ? { _meta: { pid: this.pid } } : {}) }; }
  async reset() { this.resets++; this.pid = undefined; }
  async stop() { this.stops++; this.pid = undefined; this.reject?.(Object.assign(new Error('cancelled'), { code: 'cancelled' })); this.reject = null; }
}
async function fixture(t) {
  const directory = await mkdtemp(join(tmpdir(), 'ocu-test-')); const broker = new FakeBroker(); const host = new Host({ directory, broker }); await host.start();
  const a = await new Client(directory).connect('a'); const b = await new Client(directory).connect('b');
  t.after(async () => { a.close(); b.close(); await host.close(); await rm(directory, { recursive: true, force: true }); });
  return { host, broker, a, b };
}
const observe = c => c.request('tools/call', { name: 'use_observe', arguments: { app_target: 'Fixture' } });
test('workflow ownership prevents cross-client target replacement and resets on release', async t => {
  const { broker, a, b } = await fixture(t); await observe(a);
  await assert.rejects(observe(b), { code: 'busy' });
  await a.request('release'); assert.equal(broker.resets, 1); await observe(b);
});
test('fresh client cannot execute against previous workflow coordinates', async t => {
  const { a } = await fixture(t);
  await assert.rejects(a.request('tools/call', { name: 'use_action_batch', arguments: { actions: [{ kind: 'click', at: { x: 1, y: 1 } }] } }), { code: 'observation_required' });
});
test('stop interrupts pending broker work and remains paused until resumed', async t => {
  const { host, broker, a, b } = await fixture(t); broker.block = true;
  const pending = observe(a); const rejection = assert.rejects(pending, { code: 'cancelled' });
  while (!host.inflight) await new Promise(r => setTimeout(r, 5));
  await b.request('pause'); await rejection;
  await assert.rejects(observe(a), { code: 'paused' });
  broker.block = false; await b.request('resume'); await observe(a);
});
test('permission inspection remains responsive during collection and pause without changing ownership', async t => {
  const { host, broker, a, b } = await fixture(t); broker.block = true;
  const pending = observe(a); const rejection = assert.rejects(pending, { code: 'cancelled' });
  while (!host.inflight) await new Promise(r => setTimeout(r, 5));
  const owner = host.owner, active = host.active;
  const r = await b.request('tools/call', { name: 'use_permissions', arguments: {} });
  assert.equal(r.content[0].text, 'use_permissions');
  assert.equal(host.owner, owner); assert.equal(host.active, active); assert.equal(host.inflight, true);
  await b.request('pause'); await rejection;
  const paused = await b.request('tools/call', { name: 'use_permissions', arguments: {} });
  assert.equal(paused.content[0].text, 'use_permissions'); assert.equal(host.paused, true);
});
test('listing apps neither takes nor disturbs a workflow, and Stop pauses it', async t => {
  const { host, broker, a, b } = await fixture(t); broker.block = true;
  const pending = observe(a); const rejection = assert.rejects(pending, { code: 'cancelled' });
  while (!host.inflight) await new Promise(r => setTimeout(r, 5));
  const owner = host.owner, active = host.active;
  const r = await b.request('tools/call', { name: 'use_list_apps', arguments: {} });
  assert.equal(r.content[0].text, 'apps');
  assert.equal(host.owner, owner); assert.equal(host.active, active); assert.equal(host.inflight, true);
  await assert.rejects(b.request('tools/call', { name: 'use_list_apps', arguments: { app: 'x' } }), { code: 'invalid_arguments' });
  await b.request('pause'); await rejection;
  await assert.rejects(b.request('tools/call', { name: 'use_list_apps', arguments: {} }), { code: 'paused' });
  assert.equal(host.owner, null);
});
test('only finite tools and protocol versions are accepted', async t => {
  const { a } = await fixture(t);
  await assert.rejects(a.request('tools/call', { name: 'shell' }), { code: 'unknown_tool' });
  await assert.rejects(a.request('status', {}, { v: 999 }), { code: 'version_mismatch' });
});
test('disconnect clears execution ownership before another workflow starts', async t => {
  const { host, a, b } = await fixture(t); await observe(a); a.close();
  for (let i = 0; i < 100 && host.owner; i++) await new Promise(r => setTimeout(r, 5));
  assert.equal(host.owner, null); await observe(b);
});
test('idle native cleanup failure keeps the control server alive and preserves ownership', async t => {
  const { host, broker, a, b } = await fixture(t); await observe(a);
  const owner=host.owner;
  broker.reset=async()=>{broker.resets++;throw Object.assign(Error('Reading background app state failed (AXError -25204).'),{code:'background_focus_cleanup_failed'});};
  host.workflows.get(owner).lastActivity=Date.now()-host.idleMs-1;
  await host.expireIdleOwner();
  const state=await b.request('status');
  assert.equal(state.owner,owner);assert.equal(state.stopping,false);
  assert.equal(state.cleanup_error.code,'background_focus_cleanup_failed');
  assert.match(state.cleanup_error.message,/-25204/);
  await host.expireIdleOwner();assert.equal(broker.resets,1);
  const permissions=await b.request('tools/call',{name:'use_permissions',arguments:{}});
  assert.equal(permissions.content[0].text,'use_permissions');
  await assert.rejects(observe(b),{code:'busy'});
  broker.reset=async()=>{broker.resets++;};
  host.workflows.get(owner).lastActivity=Date.now()-host.idleMs-1;
  await host.expireIdleOwner();
  const restored=await b.request('status');assert.equal(restored.owner,null);assert.equal(restored.cleanup_error,undefined);
  await observe(b);
});

test('Pause survives host replacement and only explicit Resume clears it', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'ocu-pause-'));
  let host, client;
  t.after(async () => { client?.close(); await host?.close(); await rm(directory, { recursive:true, force:true }); });
  host = new Host({ directory, broker:new FakeBroker() }); await host.start();
  client = await new Client(directory).connect('first'); await client.request('pause');
  assert.equal((await stat(join(directory,'control-state.json'))).mode & 0o777, 0o600);
  client.close(); await host.close();
  host = new Host({ directory, broker:new FakeBroker() }); await host.start();
  client = await new Client(directory).connect('replacement');
  assert.equal((await client.request('status')).paused, true);
  await assert.rejects(observe(client), { code:'paused' });
  await client.request('tools/call', { name:'use_permissions', arguments:{} });
  await client.request('resume'); await observe(client);
  assert.equal(JSON.parse(await readFile(join(directory,'control-state.json'),'utf8')).paused, false);
});
test('migration preserves existing paused status and damaged state remains paused', async t => {
  for (const [name, content] of [['status.json','{"paused":true}'], ['control-state.json','broken']]) {
    const directory = await mkdtemp(join(tmpdir(), 'ocu-pause-migrate-'));
    await writeFile(join(directory,name),content,{mode:0o600});
    const host = new Host({ directory, broker:new FakeBroker() }); await host.start();
    const client = await new Client(directory).connect('inspect');
    try { assert.equal((await client.request('status')).paused,true); await assert.rejects(observe(client),{code:'paused'}); }
    finally { client.close(); await host.close(); await rm(directory,{recursive:true,force:true}); }
  }
});

// Concurrent agents: one private engine per client, one client per app.
async function agents(t) {
  const directory = await mkdtemp(join(tmpdir(), 'ocu-agents-')); const brokers = [];
  const host = new Host({ directory, createBroker: () => { const b = new FakeBroker(); brokers.push(b); return b; } }); await host.start();
  const a = await new Client(directory).connect('a'); const b = await new Client(directory).connect('b');
  t.after(async () => { a.close(); b.close(); await host.close(); await rm(directory, { recursive: true, force: true }); });
  return { host, brokers, a, b };
}
const observeApp = (c, app) => c.request('tools/call', { name: 'use_observe', arguments: { app_target: app } });
const act = c => c.request('tools/call', { name: 'use_action_batch', arguments: { actions: [{ kind: 'click', at: { x: 1, y: 1 } }] } });
test('two agents work in different apps at the same time, each in its own engine', async t => {
  const { host, brokers, a, b } = await agents(t);
  for (const x of brokers) x.block = true;
  const pendingA = observeApp(a, 'Fixture'), pendingB = observeApp(b, 'Other');
  while (brokers.filter(x => x.calls.length).length < 2) await new Promise(r => setTimeout(r, 5));
  // Both observations are in flight together, in separate engines.
  assert.deepEqual(brokers.slice(1).map(x => x.calls.map(c => c[1].app_target)), [['Fixture'], ['Other']]);
  for (const x of brokers) x.block = false;
  for (const x of brokers.slice(1)) x.reject?.(Object.assign(new Error('retry'), { code: 'retry' }));
  await Promise.allSettled([pendingA, pendingB]);
  await observeApp(a, 'Fixture'); await observeApp(b, 'Other'); await act(a); await act(b);
  const status = await a.request('status');
  assert.deepEqual(status.workflows.map(w => w.app_pid).sort(), [101, 202]);
  assert.ok(status.clients.every(c => c.ownsExecution));
  assert.equal(brokers[0].calls.length, 0, 'The read-only broker never runs an engine call');
});
test('a second agent cannot claim an app another agent is working in, before anything is collected', async t => {
  const { brokers, a, b } = await agents(t);
  await observeApp(a, 'Fixture');
  await assert.rejects(observeApp(b, 'Fixture'), { code: 'busy' });
  assert.equal(brokers[2]?.calls.length ?? 0, 0, "b's engine collected nothing");
  // Opening the claimed app inside a batch is refused the same way.
  await assert.rejects(b.request('tools/call', { name: 'use_action_batch', arguments: { actions: [{ kind: 'open_app', name: 'Fixture' }] } }), { code: 'busy' });
  await a.request('release'); await observeApp(b, 'Fixture');
});
test('an agent moving to another app frees its previous app', async t => {
  const { a, b } = await agents(t);
  await observeApp(a, 'Fixture'); await observeApp(a, 'Other');
  await observeApp(b, 'Fixture');
  await assert.rejects(observeApp(b, 'Other'), { code: 'busy' });
});
test('cancel stops only the calling agent; Stop and disconnect end the right workflows', async t => {
  const { host, brokers, a, b } = await agents(t);
  await observeApp(a, 'Fixture'); await observeApp(b, 'Other');
  const [ea, eb] = [host.workflows.get([...host.workflows.keys()][0]).broker, host.workflows.get([...host.workflows.keys()][1]).broker];
  await a.request('cancel');
  assert.equal(ea.stops, 1); assert.equal(eb.stops, 0);
  assert.deepEqual((await b.request('status')).workflows.map(w => w.app_pid), [202]);
  await act(b);
  b.close();
  for (let i = 0; i < 100 && host.workflows.size > 1; i++) await new Promise(r => setTimeout(r, 5));
  assert.equal(eb.stops, 1); assert.equal(host.workflows.size, 1);
  await observeApp(a, 'Other'); await a.request('pause');
  assert.equal(ea.stops, 2); assert.equal((await a.request('status')).workflows.length, 0);
  assert.ok(brokers.length >= 3);
});
test('an action from an agent without its own observation is refused even while another agent works', async t => {
  const { a, b } = await agents(t);
  await observeApp(a, 'Fixture');
  await assert.rejects(act(b), { code: 'observation_required' });
});

test('each agent cursor is published for the window it acts in and cleared when its workflow ends', async t => {
  const { host, brokers, a, b } = await agents(t);
  const read = async () => JSON.parse(await readFile(join(host.directory, 'cursors.json'), 'utf8'));
  await observeApp(a, 'Fixture'); await observeApp(b, 'Other');
  const [wa, wb] = [...host.workflows.values()];
  wa.broker.onCursor({ pid: 101, window_id: 7, x: 10, y: 20, kind: 'click' });
  wb.broker.onCursor({ pid: 202, window_id: 9, x: 30, y: 40, kind: 'type' });
  wb.broker.onCursor({ pid: 202, window_id: 9, x: 'bad', y: 40 }); // ignored
  await host.cursorWriting;
  let cursors = await read();
  assert.deepEqual(cursors.map(c => [c.name, c.slot, c.pid, c.window_id, c.x, c.y, c.kind]), [['a', 0, 101, 7, 10, 20, 'click'], ['b', 1, 202, 9, 30, 40, 'type']]);
  // A cursor belongs to the app its workflow holds: moving to another app hides it.
  wa.broker.onCursor({ pid: 999, window_id: 3, x: 1, y: 1, kind: 'click' }); await host.cursorWriting;
  assert.deepEqual((await read()).map(c => c.name), ['b']);
  await b.request('release'); await host.cursorWriting;
  assert.deepEqual(await read(), []);
  assert.ok(brokers.length >= 3);
});
