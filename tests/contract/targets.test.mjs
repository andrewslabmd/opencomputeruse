import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm, readFile, writeFile, rename, readdir, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Host } from '../../packages/host/server.mjs';
import { Client } from '../../packages/cli/client.mjs';
import { Broker } from '../../packages/host/broker.mjs';
import { MAX_FRAME } from '../../packages/protocol/index.mjs';

const target = (pid = 101, main_window_id = 7) => ({ pid, app_name: 'Fixture', bundle_id: 'test.fixture', window_ids: [7, 9], main_window_id });
const observe = (client, app_target = 'Fixture') => client.request('tools/call', { name: 'use_observe', arguments: { app_target } });
const act = client => client.request('tools/call', { name: 'use_action_batch', arguments: { actions: [{ kind: 'click', at: { x: 1, y: 1 } }] } });
const tick = () => new Promise(resolve => setTimeout(resolve, 5));
class FakeBroker {
  async resolveApplication(name) { return name === 'Other' ? 202 : 101; }
  async call(name, args) {
    if (name === 'use_observe') this.pid = await this.resolveApplication(args.app_target);
    if (this.fail === 'throw') throw Error('observation failed');
    if (this.fail) return { isError: true, content: [] };
    this.onTarget(target(this.pid, name === 'use_observe' ? 7 : 9));
    if (this.block) await new Promise((resolve, reject) => { this.unblock = resolve; this.reject = reject; });
    return { _meta: { pid: this.pid }, content: [{ type: 'text', text: name }] };
  }
  async reset() {}
  async stop() { this.reject?.(Error('cancelled')); }
}
async function fixture(t) {
  const directory = await mkdtemp(join(tmpdir(), 'ocu-targets-'));
  const host = new Host({ directory, createBroker: () => new FakeBroker() }); await host.start();
  const a = await new Client(directory).connect('Alpha'), b = await new Client(directory).connect('Beta');
  const read = async () => { await host.targetWriting; return JSON.parse(await readFile(join(directory, 'targets.json'), 'utf8')); };
  t.after(async () => { a.close(); b.close(); await host.close(); await rm(directory, { recursive: true, force: true }); });
  return { host, a, b, read, directory };
}
test('targets publish after observe and action with separate workflow names, slots and busy changes', async t => {
  const { host, a, b, read, directory } = await fixture(t);
  await observe(a); await observe(b, 'Other');
  const [wa, wb] = [...host.workflows.values()];
  const rows = await read();
  assert.deepEqual(rows.map(r => [r.client, r.name, r.slot, r.busy, r.pid, r.main_window_id]),
    [[wa.id, 'Alpha', 0, false, 101, 7], [wb.id, 'Beta', 1, false, 202, 7]]);
  assert.deepEqual(rows[0], { client: wa.id, name: 'Alpha', slot: 0, busy: false, ...target(), at: rows[0].at });
  assert.ok(Number.isFinite(rows[0].at));
  assert.equal((await stat(join(directory, 'targets.json'))).mode & 0o777, 0o600);
  wa.broker.block = true;
  const pending = act(a);
  while (!wa.broker.unblock) await tick();
  assert.deepEqual((await read()).map(r => [r.busy, r.main_window_id]), [[true, 9], [false, 7]]);
  wa.broker.unblock(); await pending;
  assert.equal((await read())[0].busy, false);
  const before = await stat(join(directory, 'targets.json'));
  await host.publishTargets(); await host.publish();
  const after = await stat(join(directory, 'targets.json'));
  assert.equal(after.ino, before.ino, 'unchanged content is not rewritten');
  assert.equal(after.mtimeMs, before.mtimeMs);
});
for (const lifecycle of ['release', 'cancel', 'Stop', 'disconnect', 'idle expiry', 'failed observation', 'thrown observation']) {
  test(`target withdrawn on ${lifecycle}`, async t => {
    const { host, a, b, read } = await fixture(t); await observe(a); await observe(b, 'Other');
    const [wa] = [...host.workflows.values()];
    if (lifecycle === 'Stop') await a.request('pause');
    else if (lifecycle === 'disconnect') {
      a.close(); while (host.workflows.has(wa.id)) await tick();
    } else if (lifecycle === 'idle expiry') {
      wa.lastActivity = Date.now() - host.idleMs - 1; await host.expireIdleOwner();
    } else if (lifecycle.includes('observation')) {
      wa.broker.fail = lifecycle.startsWith('thrown') ? 'throw' : true;
      if (wa.broker.fail === 'throw') await assert.rejects(observe(a), /observation failed/);
      else assert.equal((await observe(a)).isError, true);
    } else await a.request(lifecycle);
    assert.deepEqual((await read()).map(r => r.name), lifecycle === 'Stop' ? [] : ['Beta']);
  });
}
test('target validates notification data, matches ownership, and omits a null main window', async t => {
  const { host, a, read } = await fixture(t); await observe(a);
  const wf = [...host.workflows.values()][0], original = await read();
  for (const bad of [null, { pid: 1.1 }, { app_name: 9 }, { app_name: '' }, { app_name: 'x'.repeat(MAX_FRAME + 1) }, { bundle_id: {} }, { bundle_id: '' }, { bundle_id: 'x'.repeat(MAX_FRAME + 1) }, { window_ids: [NaN] },
    { window_ids: ['7'] }, { window_ids: null }, { main_window_id: Infinity }, { main_window_id: '7' }]) {
    wf.broker.onTarget(bad === null ? null : { ...target(), ...bad });
    assert.deepEqual(await read(), original);
  }
  wf.broker.onTarget({ ...target(), app_name: null, bundle_id: null });
  assert.equal((await read())[0].app_name, null);
  wf.broker.onTarget(target(999)); assert.deepEqual(await read(), []);
  wf.broker.onTarget({ ...target(), window_ids: [], main_window_id: null }); assert.deepEqual(await read(), []);
  await observe(a); await a.request('release');
  // Reacquiring ownership without a new notification cannot resurrect a target.
  wf.pid = 101; await host.publishTargets(); assert.deepEqual(await read(), []);
});
test('hotkey keeps only the previous point for the same pid and window', async t => {
  const { host, a } = await fixture(t); await observe(a);
  const wf = [...host.workflows.values()][0];
  const read = async () => { await host.cursorWriting; return JSON.parse(await readFile(join(host.directory, 'cursors.json'), 'utf8')); };
  wf.broker.onCursor({ pid: 101, window_id: 7, kind: 'hotkey' }); assert.deepEqual(await read(), []);
  wf.broker.onCursor({ pid: 101, window_id: 7, kind: 'drag', x: 10, y: 20, to_x: 30, to_y: 40 });
  const previous = (await read())[0];
  await tick();
  wf.broker.onCursor({ pid: 101, window_id: 9, kind: 'hotkey' }); assert.deepEqual((await read())[0], previous);
  wf.broker.onCursor({ pid: 202, window_id: 7, kind: 'hotkey' }); assert.deepEqual((await read())[0], previous);
  wf.broker.onCursor({ pid: 101, window_id: 7, kind: 'hotkey' });
  const current = (await read())[0];
  assert.deepEqual([current.x, current.y, current.kind], [10, 20, 'hotkey']);
  assert.ok(current.at > previous.at); assert.equal('to_x' in current, false); assert.equal('to_y' in current, false);
});
test('concurrent reader sees complete targets through writes and atomic shutdown', async t => {
  const { host, a, read, directory } = await fixture(t); await observe(a);
  const wf = [...host.workflows.values()][0];
  let reading = true, reads = 0;
  const reader = (async () => {
    while (reading) {
      const rows = JSON.parse(await readFile(join(directory, 'targets.json'), 'utf8'));
      assert.ok(Array.isArray(rows)); reads++;
    }
  })();
  try {
    for (let i = 0; i < 100; i++) { wf.broker.onTarget(target(101, i)); await host.targetWriting; }
    await host.close(); assert.deepEqual(await read(), []);
    assert.equal((await stat(join(directory, 'targets.json'))).mode & 0o777, 0o600);
  } finally { reading = false; await reader; }
  assert.ok(reads > 0);
  assert.equal((await readdir(directory)).some(name => name.startsWith('targets.json.')), false);
});

// Exercise the real engine and broker using the helper's file protocol, without native actions.
async function engineFixture(t, raw) {
  const directory = await mkdtemp(join(tmpdir(), 'ocu-engine-targets-'));
  const events = [], requests = [];
  const broker = new Broker(process.execPath, ['packages/engine/computer-use-mcp.mjs'],
    { ...process.env, OCU_COMPUTER_USE_HELPER_COMMAND_DIRECTORY: directory });
  broker.onTarget = params => events.push({ method: 'target', ...params });
  broker.onCursor = params => events.push({ method: 'cursor', ...params });
  let running = true, failure;
  const worker = (async () => {
    while (running) {
      for (const name of await readdir(directory)) {
        if (!/^request-.*\.json$/.test(name)) continue;
        const request = JSON.parse(await readFile(join(directory, name), 'utf8'));
        requests.push(request);
        let payload = {};
        if (request.action === 'accessibilitySnapshot') payload = raw;
        if (request.action === 'beginActionFocus') payload = { token: 'test', mode: 'synthetic' };
        assert.notEqual(request.action, 'keyboardTarget', 'no extra native request for the cursor');
        if (request.action === 'sendHotkey') {
          assert.equal(events.at(-1)?.kind, 'hotkey', 'cursor precedes dispatch');
          payload = { window_id: 9 };
        }
        if (request.action === 'accessibilityInteraction') payload = { status: 'completed', behavior: 'press', native_operations: [] };
        await rm(join(directory, name));
        const path = join(directory, `response-${request.id}.json`);
        await writeFile(path + '.tmp', JSON.stringify({ id: request.id, success: true, stdout: JSON.stringify(payload) }));
        await rename(path + '.tmp', path);
      }
      await tick();
    }
  })().catch(error => { failure = error; });
  t.after(async () => { await broker.stop(); running = false; await worker; await rm(directory, { recursive: true, force: true }); if (failure) throw failure; });
  return { broker, events, requests, raw };
}
const window = (windowID, zIndex, role = 'AXWindow') => ({ windowID, zIndex, frame: { x: 0, y: 0, w: 100, h: 100 },
  tree: { id: `w${windowID}`, role, frame: { x: 0, y: 0, w: 100, h: 100 }, children: [] } });
const snapshot = windows => ({ app: { pid: 101, name: 'Fixture', bundleIdentifier: 'test.fixture' }, capturedAt: 1,
  nodeCount: windows.length, surface: { frame: { x: 0, y: 0, w: 100, h: 100 }, windows, captureWindowIDs: windows.map(w => w.windowID) } });
for (const [name, windows, anchor, expected] of [
  ['scoped anchor takes priority', [window(7, 0), window(9, 1)], 9, 9],
  ['lowest zIndex AXWindow wins over earlier non-window roots', [window(7, 0, 'AXMenu'), window(9, 2), window(11, 1)], undefined, 11],
  ['without AXWindow roots the lowest zIndex wins', [window(7, 2, 'AXMenu'), window(9, 0, 'AXGroup')], undefined, 9],
  ['without windows main is null', [], undefined, null],
]) {
  test(`engine observation target: ${name}`, async t => {
    const raw = snapshot(windows);
    if (anchor !== undefined) raw.surface.anchorWindowID = anchor;
    if (!windows.length) raw.surface.unavailable = true;
    const { broker, events } = await engineFixture(t, raw);
    await broker.start(); const result = await broker.request('tools/call', { name: 'use_observe', arguments: { app_target: 'Fixture' } });
    assert.equal(result.isError, undefined);
    assert.deepEqual(events, [{ method: 'target', ...target(101, expected), window_ids: windows.map(w => w.windowID) }]);
  });
}
test('engine action window survives post-action observation and hotkey publishes before dispatch', async t => {
  const { broker, events } = await engineFixture(t, snapshot([window(7, 0), window(9, 1)]));
  await broker.start();
  await broker.request('tools/call', { name: 'use_observe', arguments: { app_target: 'Fixture' } });
  await broker.request('tools/call', { name: 'use_action_batch', arguments: { settle_ms: 0, actions: [{ kind: 'click', element: 'w9' }] } });
  assert.deepEqual(events.filter(e => e.method === 'target').map(e => e.main_window_id), [7, 9, 9]);
  assert.ok(events.some(e => e.method === 'cursor' && e.window_id === 9 && e.kind === 'click'));
  await broker.request('tools/call', { name: 'use_action_batch', arguments: { settle_ms: 0, actions: [{ kind: 'hotkey', keys: ['cmd', 'b'] }] } });
  assert.deepEqual(events.filter(e => e.method === 'cursor').at(-1), { method: 'cursor', pid: 101, window_id: 9, kind: 'hotkey' });
  await broker.request('tools/call', { name: 'use_observe', arguments: { app_target: 'Fixture' } });
  assert.equal(events.filter(e => e.method === 'target').at(-1).main_window_id, 7, 'explicit observation selects its own window again');
});
test('engine sends null for missing app metadata', async t => {
  const raw = snapshot([window(7, 0)]); delete raw.app.name; delete raw.app.bundleIdentifier;
  const { broker, events } = await engineFixture(t, raw); await broker.start();
  await broker.request('tools/call', { name: 'use_observe', arguments: { app_target: 'Fixture' } });
  assert.equal(events[0].app_name, null); assert.equal(events[0].bundle_id, null);
});

test('engine target retains the complete proven capture set, including non-AX capture windows', async t => {
  const raw = snapshot([window(7, 0)]); raw.surface.captureWindowIDs = [7, 99];
  const { broker, events } = await engineFixture(t, raw); await broker.start();
  await broker.request('tools/call', { name: 'use_observe', arguments: { app_target: 'Fixture' } });
  assert.deepEqual(events[0].window_ids, [7, 99]);
});
test('cancel withdraws an in-flight target and late notifications cannot restore it', async t => {
  const { host, a, read } = await fixture(t); await observe(a);
  const wf = [...host.workflows.values()][0]; wf.broker.block = true;
  const pending = act(a), rejection = assert.rejects(pending, /cancelled/);
  while (!wf.broker.unblock) await tick();
  wf.broker.stop = async () => {
    assert.deepEqual(await read(), []);
    wf.broker.onTarget(target()); assert.deepEqual(await read(), []);
    wf.broker.reject(Error('cancelled'));
  };
  await a.request('cancel'); await rejection;
  assert.deepEqual(await read(), []);
});
test('release withdraws before cleanup, including cleanup failure, without changing ownership', async t => {
  const { host, a, read } = await fixture(t); await observe(a);
  const wf = [...host.workflows.values()][0];
  wf.broker.reset = async () => { assert.deepEqual(await read(), []); throw Error('cleanup failed'); };
  await assert.rejects(a.request('release'), /cleanup failed/);
  assert.equal(wf.pid, 101); assert.deepEqual(await read(), []);
});
