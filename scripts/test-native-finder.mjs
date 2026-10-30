import assert from 'node:assert/strict';
import { spawn, execFileSync } from 'node:child_process';
import { mkdir, writeFile, readFile, readdir } from 'node:fs/promises';
import { resolve, join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { createInterface } from 'node:readline';
import { parse } from 'yaml';
import { Client } from '../packages/cli/client.mjs';
import { flat, finderObservationNodes, finderItem as item } from './live-support/finder-targets.mjs';

// No app launch/quit, foreground activation or installed-bundle changes. Uses
// packaged components only when no OCU service is running (one host per user).
if (!process.argv.includes('--interactive')) throw Error('Finder acceptance requires --interactive');
const app = resolve('dist/Open Computer Use.app');
const run = `work/finder-${Date.now()}`; // Short relative Unix socket path on macOS.
const base = resolve(run), fixture = join(base, 'OCU Finder Test');
const fixtureURL = pathToFileURL(fixture).href + '/';
const commands = join(base, 'helper-commands');
const helperPath = join(app, 'Contents/Resources/Open Computer Use Helper.app/Contents/MacOS/ocu-helper');
const hostPath = join(app, 'Contents/MacOS/ocu-host');
const enginePath = join(app, 'Contents/MacOS/ocu-engine');
const sleep = ms => new Promise(r => setTimeout(r, ms));
const point = n => ({ x: n.frame[0] + n.frame[2] / 2, y: n.frame[1] + n.frame[3] / 2 });
const records = [], cases = [], children = new Set();
let helper, host, monitor, client, windowID, lastGuard, heartbeat = 0, stopped, watchdog, foreground, pointer;
const save = (name, value) => writeFile(join(base, name), JSON.stringify(value, null, 2));
function assertNoOtherServices() {
  const running = execFileSync('/bin/ps', ['-axo', 'pid=,comm='], { encoding: 'utf8' }).split('\n')
    .map(line => line.trim().match(/^(\d+)\s+(.*)$/)).filter(Boolean)
    .filter(([, pid, path]) => /\/(?:OpenComputerUse|ocu-host|ocu-helper|ocu-engine)$/.test(path) && Number(pid) !== helper?.pid);
  assert.equal(running.length, 0, 'Quit Open Computer Use yourself before this isolated development-component test; the harness never quits apps');
}
function abort(reason) {
  if (stopped) return;
  stopped = reason; console.error(`STOP: ${reason}. No further GUI actions or GUI cleanup will run.`);
  // Cancellation interrupts an in-flight workflow; previously dispatched events
  // cannot be recalled. Kill an in-flight scripting read/setup operation too.
  for (const child of children) child.kill('SIGTERM');
  if (client?.connected) void client.send(client.conn, 'cancel').catch(() => {});
}
function guard() {
  if (stopped) throw Error(stopped);
  if (lastGuard?.state !== 'ready' || Date.now() - heartbeat > 1500) throw Error('Input guard is not ready');
}
function command(binary, args) {
  guard();
  return new Promise((yes, no) => {
    const child = spawn(binary, args, { stdio: ['ignore', 'pipe', 'pipe'] }); children.add(child);
    let out = '', err = '';
    const timer = setTimeout(() => { child.kill('SIGTERM'); no(Error(`${binary} timed out`)); }, 15000);
    child.stdout.on('data', d => { out += d; }); child.stderr.on('data', d => { err += d; });
    child.on('error', no);
    child.on('close', code => { clearTimeout(timer); children.delete(child); if (stopped) no(Error(stopped)); else code === 0 ? yes(out.trim()) : no(Error(err || `${binary}: ${code}`)); });
  });
}
async function jxa(code) { return JSON.parse(await command('/usr/bin/osascript', ['-l', 'JavaScript', '-e', code])); }
async function state() {
  return jxa(`JSON.stringify(Application('Finder').windows().flatMap(w=>{try{const url=w.target().url();return url.startsWith(${JSON.stringify(fixtureURL)})?[{id:w.id(),url}]:[]}catch{return []}}))`);
}
async function reset() {
  const windows = await state(); assert.ok(windows.some(w => w.id === windowID), 'Owned root disappeared');
  for (const w of windows.filter(w => w.id !== windowID)) await command('/usr/bin/osascript', ['-e', `tell application "Finder" to close Finder window id ${w.id}`]);
  await command('/usr/bin/osascript', ['-e', `tell application "Finder"
set target of Finder window id ${windowID} to (POSIX file ${JSON.stringify(fixture)} as alias)
set current view of Finder window id ${windowID} to icon view
end tell`]);
  await sleep(300); guard();
}
async function call(name, args) {
  guard();
  const raw = await client.request('tools/call', { name, arguments: args });
  const result = parse(raw.content?.find(v => v.type === 'text')?.text ?? 'null');
  for (const [i, image] of (raw.content ?? []).filter(v => v.type === 'image').entries()) {
    await writeFile(join(base, `capture-${records.length}-${i}.png`), Buffer.from(image.data, 'base64'));
  }
  records.push({ name, args, result, isError: raw.isError }); await save('records.json', records);
  guard(); assert.notEqual(raw.isError, true, JSON.stringify(result));
  for (const action of result.actions ?? []) {
    assert.ok(!action.foreground_guard?.length, 'Finder attempted a foreground switch');
    assert.notEqual(action.background_focus?.mode, 'user_active', 'Background path was not exercised');
    if (action.input_trace_ids?.length) {
      assert.equal(action.input_delivery?.length, action.input_trace_ids.length, 'Every dispatched input needs a receipt');
    }
    for (const receipt of action.input_delivery ?? []) {
      assert.equal(receipt.violation, false); assert.equal(receipt.target_delivery_observed, true);
      assert.equal(receipt.foreground_pid_before, foreground); assert.equal(receipt.foreground_pid_after, foreground);
      assert.notEqual(receipt.target_pid, foreground, 'Finder must stay background for every input');
    }
  }
  return result;
}
async function observe() {
  const result = await call('use_observe', { app_target: 'Finder', window_id: windowID, include_screenshot: true });
  assert.ok(result.snapshot?.surface.windows.some(w => w.window_id === windowID), 'Owned observation missing');
  return finderObservationNodes(result.snapshot);
}
async function act(action, expectedFailure) {
  const result = (await call('use_action_batch', { actions: [action], diagnostics: true })).actions[0];
  if (expectedFailure) assert.equal(result.code, expectedFailure, JSON.stringify(result));
  else assert.ok(['completed', 'sent', 'unconfirmed'].includes(result.status) || (action.kind === 'right_click' && result.status === 'pending'), JSON.stringify(result));
  if (action.kind === 'hotkey' || action.click_count > 1 || action.input_method === 'pointer' || (action.kind === 'perform_action' && action.name === 'AXCancel')) {
    assert.ok(result.input_trace_ids?.length, 'Expected a process-directed input trace');
  }
  return result;
}
async function openMenu(name) {
  const target = item(await observe(), name);
  await act({ kind: 'right_click', element: target.id });
  const nodes = await observe();
  const menus = nodes.filter(n => n.role === 'AXMenu' && flat(n).some(c => c.role === 'AXMenuItem' && c.frame?.[2] > 0));
  const menu = menus.find(n => flat(n).some(c => c.name === 'Open' && c.role === 'AXMenuItem'));
  assert.ok(menu, 'Missing visible tracking menu'); assert.notEqual(menu.offscreen, true);
  return { menu, nodes };
}
async function assertMenuClosed() {
  // Independent readback, separate from the action's delta snapshot.
  for (const delay of [250, 1000]) {
    await sleep(delay);
    assert.equal((await observe()).some(n => n.role === 'AXMenu' && flat(n).some(c => c.role === 'AXMenuItem' && c.frame?.[2] > 0)), false, 'Menu still visible');
  }
}
async function assertOpened() {
  await sleep(1500); guard();
  const windows = await state();
  assert.ok(windows.some(w => w.id !== windowID && w.url === pathToFileURL(join(fixture, 'Open Me')).href + '/'), 'Folder did not open in its own fixture window');
}
async function test(name, fn) {
  try { await fn(); cases.push({ name, status: 'passed' }); console.log(`PASS ${name}`); }
  catch (error) { cases.push({ name, status: 'failed', error: error.stack }); throw error; }
  finally { await save('cases.json', cases); }
}
async function waitExit(child) {
  if (!child || child.exitCode !== null || child.signalCode !== null) return;
  child.kill('SIGTERM');
  await Promise.race([new Promise(r => child.once('exit', r)), sleep(3000)]);
  if (child.exitCode === null && child.signalCode === null) child.kill('SIGKILL');
}
process.on('SIGINT', () => abort('SIGINT')); process.on('SIGTERM', () => abort('SIGTERM'));
try {
  // Only headless build/preflight before qualification; no launch or quit.
  assertNoOtherServices();
  for (const path of [helperPath, hostPath, enginePath]) await readFile(path);
  await mkdir(commands, { recursive: true, mode: 0o700 });
  execFileSync('xcrun', ['swiftc', 'tests/native/LiveTestActivity.swift', 'scripts/live-support/main.swift', '-o', join(base, 'idle-guard')]);
  helper = spawn(helperPath, ['--parent-pid', String(process.pid), '--command-directory', commands], { stdio: ['ignore', 'ignore', 'pipe'] });
  helper.stderr.pipe(process.stderr); helper.on('error', e => abort(e.message));
  helper.on('exit', () => { if (!stopped) abort('development helper exited'); });
  monitor = spawn(join(base, 'idle-guard'), [String(helper.pid)], { stdio: ['ignore', 'pipe', 'inherit'] });
  monitor.on('error', e => abort(e.message));
  monitor.on('exit', () => { if (!stopped) abort('physical input monitor exited'); });
  const lines = createInterface({ input: monitor.stdout });
  lines.on('line', line => {
    try {
      lastGuard = JSON.parse(line); heartbeat = Date.now();
      if (lastGuard.state === 'stopped') abort(lastGuard.reason);
    } catch { abort('invalid guard state'); }
  });
  watchdog = setInterval(() => { if (Date.now() - heartbeat > 2000) abort('input guard heartbeat lost'); }, 100);
  heartbeat = Date.now();
  console.log('Waiting for unlocked screen, Finder behind another app, and 300 seconds untouched. Own input never excuses physical input.');
  while (!stopped && lastGuard?.state !== 'ready') await sleep(100);
  guard(); assertNoOtherServices(); foreground = lastGuard.foreground_pid; pointer = lastGuard.pointer;
  await save('guard-start.json', lastGuard);
  host = spawn(hostPath, [], { env: { ...process.env, OCU_RUNTIME_DIR: run, OCU_PARENT_PID: String(process.pid), OCU_ENGINE_PATH: enginePath, OCU_COMPUTER_USE_HELPER_COMMAND_DIRECTORY: commands }, stdio: ['ignore', 'ignore', 'pipe'] });
  host.stderr.pipe(process.stderr); host.on('error', e => abort(e.message));
  client = new Client(run);
  for (let i = 0; ; i++) {
    guard();
    try { await client.connect('Guarded Finder issue 7 acceptance'); break; }
    catch (error) { if (i >= 50) throw error; await sleep(100); }
  }
  const status = await client.request('status'); assert.ok(!status.paused && !status.owner && !status.workflows.length);
  const permissions = await call('use_permissions', {});
  assert.ok(permissions.permissions.every(p => p.isGranted), 'Grant development permissions manually before running; harness never prompts');
  assert.equal(await jxa(`JSON.stringify(Application('Finder').running())`), true, 'Finder must already be running');
  guard(); await mkdir(join(fixture, 'Open Me'), { recursive: true }); await mkdir(join(fixture, 'Destination'));
  await writeFile(join(fixture, 'dummy.txt'), 'Issue 7 fixture; preserved.\n');
  await writeFile(join(fixture, 'Open Me', 'inside.txt'), 'Inside fixture.\n');
  await command('/usr/bin/osascript', ['-e', `tell application "Finder"
make new alias file at (POSIX file ${JSON.stringify(fixture)} as alias) to (POSIX file ${JSON.stringify(join(fixture, 'Open Me'))} as alias) with properties {name:"Folder Alias"}
set w to make new Finder window
set target of w to (POSIX file ${JSON.stringify(fixture)} as alias)
set current view of w to icon view
set bounds of w to {250,180,950,700}
return id of w
end tell`]).then(value => { windowID = Number(value); });
  assert.ok(Number.isInteger(windowID) && windowID > 0);
  await sleep(500);
  await test('background drag reports unsupported; files preserved', async () => {
    const nodes = await observe();
    await act({ kind: 'drag', from: point(item(nodes, 'dummy.txt')), to: point(item(nodes, 'Destination')), input_method: 'pointer', duration_ms: 600 }, 'drag_and_drop_unsupported');
    assert.deepEqual(await readdir(join(fixture, 'Destination')), []);
    assert.equal(await readFile(join(fixture, 'dummy.txt'), 'utf8'), 'Issue 7 fixture; preserved.\n');
  });
  // First attempt deliberately follows the formerly failing drag sequence.
  for (let attempt = 1; attempt <= 10; attempt++) {
    await test(`background ordinary-folder double-click ${attempt}/10`, async () => {
      await act({ kind: 'click', element: item(await observe(), 'Open Me').id, click_count: 2 });
      await assertOpened(); await reset();
    });
  }
  await test('background alias double-click', async () => {
    await act({ kind: 'click', element: item(await observe(), 'Folder Alias').id, click_count: 2 });
    await assertOpened(); await reset();
  });
  await test('background pointer selection then Cmd+Down', async () => {
    await act({ kind: 'click', at: point(item(await observe(), 'Open Me')), input_method: 'pointer' });
    await observe(); await act({ kind: 'hotkey', keys: ['cmd', 'down'] }); await assertOpened(); await reset();
  });
  for (const name of ['Folder Alias', 'Open Me']) {
    await test(`background ${name} context-menu Open`, async () => {
      const { menu } = await openMenu(name);
      const open = flat(menu).find(n => n.role === 'AXMenuItem' && n.name === 'Open'); assert.ok(open);
      await act({ kind: 'click', element: open.id }); await assertOpened(); await reset();
    });
  }
  await test('background Escape closes alias menu', async () => {
    await openMenu('Folder Alias'); await act({ kind: 'hotkey', keys: ['escape'] }); await assertMenuClosed();
  });
  await test('background overflowing menu exposure and AXCancel dismissal', async () => {
    const { menu, nodes } = await openMenu('dummy.txt');
    const scroll = nodes.find(n => n.role === 'AXScrollArea' && flat(n).some(c => c.id === menu.id));
    assert.ok(scroll?.frame, 'Expected Finder menu beneath a scroll viewport');
    const bottom = scroll.frame[1] + scroll.frame[3];
    assert.ok(flat(menu).some(n => n.frame?.[1] + n.frame?.[3] > bottom && !n.offscreen), 'No exposed menu geometry beyond scroll clip; clipping case was not exercised');
    const result = await act({ kind: 'perform_action', element: menu.id, name: 'AXCancel' });
    assert.ok(result.native_operations?.some(op => op.name === 'Escape'), 'New menu cancellation path was not used');
    await assertMenuClosed();
  });
  guard(); assert.deepEqual(lastGuard.pointer, pointer); assert.equal(lastGuard.foreground_pid, foreground);
  assert.equal(await readFile(join(fixture, 'Open Me', 'inside.txt'), 'utf8'), 'Inside fixture.\n');
  assert.deepEqual(await readdir(join(fixture, 'Destination')), []);
  guard(); await client.request('release');
  // On a normal finish, close only windows whose live target is this fixture.
  for (const w of await state()) await command('/usr/bin/osascript', ['-e', `tell application "Finder" to close Finder window id ${w.id}`]);
  console.log(`Passed ${cases.length} background Finder cases. Evidence and fixture: ${base}`);
} catch (error) {
  process.exitCode = 1; console.error(error.stack);
} finally {
  clearInterval(watchdog);
  if (client?.connected) await client.send(client.conn, stopped ? 'cancel' : 'release').catch(() => {});
  client?.close();
  // No GUI cleanup on interruption/failure: leave fixture/windows for inspection.
  stopped ||= 'finished';
  await waitExit(host); await waitExit(helper); await waitExit(monitor);
  await save('summary.json', { passed: process.exitCode !== 1, stopped, windowID, fixture, cases, lastGuard }).catch(() => {});
}
