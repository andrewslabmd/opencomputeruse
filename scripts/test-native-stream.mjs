import assert from 'node:assert/strict';
import { execFileSync, spawn } from 'node:child_process';
import { mkdir, readFile, writeFile, rename, realpath, readdir, lstat, rm, rmdir } from 'node:fs/promises';
import { resolve, join, relative, isAbsolute, dirname } from 'node:path';
import { createInterface } from 'node:readline';
import { parse } from 'yaml';
import { Client } from '../packages/cli/client.mjs';
import { requestComputerUseHelper } from '../packages/engine/computer-use-helper-client.mjs';

if (!process.argv.includes('--interactive')) throw Error('Native stream check requires --interactive authorization');
const root = await realpath(resolve('.'));
const dir = join(root, 'work/stream-phase1', new Date().toISOString().replaceAll(':', '-'));
await mkdir(dir, { recursive: true, mode: 0o700 });
const runtime = resolve(process.env.OCU_RUNTIME_DIR || join(dir, 'runtime'));
process.env.OCU_RUNTIME_DIR = runtime;
const commands = join(runtime, 'helper-commands');
const results = { started: new Date().toISOString(), runtime, cases: [],
  method: { source: 'Phase 1 brief and private design/build plans (read in place)', fps: 15, cpuSeconds: 20,
    resizeDebounceMs: 300, queueDepth: 3, toleranceRGB: 16,
    ownChoices: '15 s readiness deadlines, 50 ms readiness poll, 100 ms foreground watcher, 500 ms visual settling; 16/255 tolerance per sRGB channel for lossy H.264; child palettes magenta (255,0,255), yellow (255,255,0), orange (255,128,0), at least one matching pixel. PNGs saved only on request. Resize uses 1000×600 points. RGB solid cases use (0,0.65,0.65), (0.8,0.2,0.1), (0.1,0.3,0.9). CPU uses cumulative process time over at least 20 s, sampled each second; 100% is one core.' },
  native: { status: 'not run', purplePill: 'unverified', pixels: 'unverified' }, cleanup: [] };
const run = (exe, args = []) => execFileSync(exe, args, { encoding: 'utf8' }).trim();
const sleep = ms => new Promise(r => setTimeout(r, ms));
const owned = new Set();
const agent = new Client(runtime);
let watcher, viewer, latest, devPid, helperPid, fixture, failure, intentionalCleanup = false;
let runtimeCreated = false, runtimeOwned = false;
const messages = [], watchLines = [];
const processes = () => run('ps', ['-axo', 'pid=,ppid=,args=']).split('\n').map(s => {
  const m = s.trim().match(/^(\d+)\s+(\d+)\s+(.*)$/); return m && { pid: +m[1], parent: +m[2], args: m[3] };
}).filter(Boolean);
function check() { if (failure) throw Error(failure); }
async function until(fn, label) {
  for (const end = Date.now() + 15000; Date.now() < end;) {
    check();
    try { const value = await fn(); if (value) return value; }
    catch (e) { if (e.code !== 'ENOENT' && !(e instanceof SyntaxError)) throw e; }
    await sleep(50);
  }
  throw Error(`Timed out: ${label}`);
}
async function save() {
  await writeFile(join(dir, 'results.json'), JSON.stringify(results, null, 2));
  await writeFile(join(dir, 'messages.jsonl'), messages.map(m => JSON.stringify(m)).join('\n') + '\n');
  await writeFile(join(dir, 'windows.jsonl'), watchLines.map(m => JSON.stringify(m)).join('\n') + '\n');
  await writeFile(join(dir, 'report.md'), ['# Phase 1 socket capture check', '',
    `Status: ${results.error ? 'stopped: ' + results.error : results.native.status}`, '',
    `Purple title-bar pill in simultaneous one-off: ${results.native.purplePill}`, '',
    ...results.cases.map(c => `- ${c.name}: ${JSON.stringify(c.result ?? c.error ?? 'recorded')}`), '',
    JSON.stringify(results.method, null, 2), '',
    'Native runs use only the fixture, open -g launches, an isolated dev runtime, read-only permissionStatus, the socket decoder and OCU observation. No permission requests, AppleScript, app activation, Spaces or full-screen changes. PNG existence is not a visual review. The lead must inspect the simultaneous one-off and decoded PNGs before recording a pill conclusion.', ''].join('\n'));
}
async function helper(action, payload = {}) {
  check(); const result = await requestComputerUseHelper(commands, action, payload, { timeoutMs: 30000 }); check();
  assert.equal(result.success, true, result.error); return JSON.parse(result.stdout);
}
async function command(name, extra = {}) {
  check(); const id = `${Date.now()}-${name}`;
  await writeFile(fixture.command + '.tmp', JSON.stringify({ id, command: name, ...extra }));
  await rename(fixture.command + '.tmp', fixture.command);
  const state = await until(async () => { const s = JSON.parse(await readFile(fixture.state, 'utf8')); return s.last_command === id && s; }, name);
  assert.equal(state.command_error, null);
  assert.equal(state.active, false);
  assert.ok(!state.foreground_changes.some(c => owned.has(c.to)), 'Owned app came to front');
  return state;
}
const send = control => { check(); viewer.stdin.write(JSON.stringify(control) + '\n'); };
async function snapshot(label) {
  send({ snapshot: label });
  return until(() => messages.find(m => m.type === 'png' && m.label === label), `decoded ${label}`);
}
async function targetState(state, from = messages.length) {
  return until(() => messages.slice(from).find(m => m.type === 'target' && m.state === state), `target ${state}`);
}
async function caseRun(name, fn) {
  check(); console.log(name);
  const row = { name, started: Date.now(), frontBefore: latest?.frontmost }; results.cases.push(row);
  try { row.result = await fn(); }
  catch (error) { row.error = String(error); throw error; }
  finally { row.finished = Date.now(); row.frontAfter = latest?.frontmost; await save(); }
  check();
}
function cpuSample() {
  const [time, rss] = run('ps', ['-p', String(helperPid), '-o', 'time=,rss=']).split(/\s+/);
  const seconds = time.split(':').map(Number).reduce((total, n) => total * 60 + n, 0);
  return { at: performance.now(), cpuSeconds: seconds, rssKB: +rss };
}
function watchProcess(child, name) {
  child.on('error', e => { failure = `${name}: ${e.message}`; });
  child.on('exit', code => { if (!intentionalCleanup) failure = `${name} exited ${code}`; });
  child.stderr.on('data', data => { (results.processStderr ??= []).push({ name, text: data.toString() }); });
}
const app = join(root, 'dist/Open Computer Use.app');
const appBinary = join(app, 'Contents/MacOS/OpenComputerUse');
try {
  const withinWork = relative(join(root, 'work'), runtime);
  const approvedRuntime = join(dirname(run('git', ['rev-parse', '--path-format=absolute', '--git-common-dir'])), 'work/p13');
  assert.ok((!withinWork.startsWith('..') && !isAbsolute(withinWork)) || runtime === approvedRuntime,
    'Runtime must be inside this worktree/work or the lead-approved canonical work/p13');
  // Darwin sockaddr_un.sun_path is 104 bytes including its NUL terminator.
  results.socketPathBytes = Buffer.byteLength(join(runtime, 'stream.sock')) + 1;
  assert.ok(results.socketPathBytes <= 104,
    `Runtime socket requires ${results.socketPathBytes} bytes including NUL; macOS sockaddr_un.sun_path allows 104. This worktree cannot fit even work/r/stream.sock (${Buffer.byteLength(join(root, 'work/r/stream.sock')) + 1} bytes). No apps launched; no runtime outside this worktree substituted.`);
  assert.ok(!processes().some(p => p.args === appBinary), 'This worktree dev app is already running; refusing to take ownership');
  try {
    const stat = await lstat(runtime);
    assert.ok(stat.isDirectory() && !stat.isSymbolicLink() && (stat.mode & 0o777) === 0o700, 'Runtime must be a real mode-0700 directory');
    assert.deepEqual(await readdir(runtime), [], 'Refusing a nonempty runtime; another run may own it');
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
    await mkdir(runtime, { mode: 0o700 }); runtimeCreated = true;
  }
  runtimeOwned = true;
  const decoder = join(dir, 'stream-client');
  run('xcrun', ['swiftc', '-D', 'STREAM_NATIVE_CLIENT', '-parse-as-library', 'tests/native/StreamSocketClient.swift', '-o', decoder]);
  watcher = spawn(decoder, ['--watch'], { stdio: ['ignore', 'pipe', 'pipe'] }); owned.add(watcher.pid);
  watchProcess(watcher, 'watcher');
  createInterface({ input: watcher.stdout }).on('line', line => {
    try {
      latest = JSON.parse(line); watchLines.push(latest);
      if (owned.has(latest.frontmost)) failure = `OCU or fixture came to front: ${latest.frontmost}`;
    } catch (e) { failure = e.message; }
  });
  await until(() => latest, 'foreground watcher');
  results.frontmostBefore = latest.frontmost;
  run('open', ['-g', '-n', '--env', `OCU_RUNTIME_DIR=${runtime}`, app]);
  devPid = (await until(() => processes().find(p => p.args === appBinary), 'dev app')).pid; owned.add(devPid);
  helperPid = (await until(() => processes().find(p => p.parent === devPid && p.args.includes('--command-directory ' + commands)), 'dev helper')).pid;
  results.processes = { devPid, helperPid };
  results.permissions = await helper('permissionStatus');
  assert.ok(results.permissions.find(p => p.name === 'Screen Recording')?.isGranted,
    'Screen Recording is not granted to the dev helper; stopped without requesting it');
  await until(async () => { await readFile(join(runtime, 'host-token')); return processes().some(p => p.parent === devPid && p.args.includes('ocu-host')); }, 'dev host');
  const bundle = join(dir, 'StreamFixture.app');
  await mkdir(join(bundle, 'Contents/MacOS'), { recursive: true });
  run('xcrun', ['swiftc', 'tests/native-fixtures/StreamFixture.swift', '-o', join(bundle, 'Contents/MacOS/StreamFixture')]);
  await writeFile(join(bundle, 'Contents/Info.plist'), `<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleName</key><string>OCU Stream Fixture</string><key>CFBundleExecutable</key><string>StreamFixture</string><key>CFBundleIdentifier</key><string>com.andrewslabmd.opencomputeruse.streamfixture</string><key>CFBundlePackageType</key><string>APPL</string><key>LSUIElement</key><true/></dict></plist>`);
  fixture = { state: join(dir, 'fixture.json'), command: join(dir, 'command.json') };
  run('open', ['-g', '-n', bundle, '--args', fixture.state, fixture.command]);
  const state = await until(async () => JSON.parse(await readFile(fixture.state, 'utf8')), 'fixture launch');
  fixture.pid = state.pid; fixture.window = state.window; owned.add(state.pid); results.fixture = state;
  assert.equal(state.active, false, 'Fixture activated at launch');
  assert.ok(!state.foreground_changes.some(c => owned.has(c.to)), 'Owned app activated during fixture launch');
  assert.ok(!watchLines.some(s => owned.has(s.frontmost)), 'Owned app appeared in the foreground watcher');
  await until(() => latest.windows.find(w => w.id === state.window && w.bounds.Width > 0), 'fixture window');
  await agent.connect('Stream acceptance');
  const observed = await agent.request('tools/call', { name: 'use_observe', arguments: { app_target: `PID:${fixture.pid}` } });
  assert.notEqual(observed.isError, true, JSON.stringify(observed));
  const observation = parse(observed.content.find(c => c.type === 'text').text);
  assert.ok(observation.snapshot, 'Fixture observation succeeded');
  const target = await until(async () => (JSON.parse(await readFile(join(runtime, 'targets.json'), 'utf8'))).find(t => t.pid === fixture.pid), 'observed target');
  results.agent = target.client;
  await mkdir(join(dir, 'frames'), { recursive: true });
  viewer = spawn(decoder, [runtime, join(dir, 'frames')], { stdio: ['pipe', 'pipe', 'pipe'] }); owned.add(viewer.pid);
  watchProcess(viewer, 'decoder');
  createInterface({ input: viewer.stdout }).on('line', line => {
    try { const message = JSON.parse(line); messages.push({ ...message, receivedAt: Date.now() }); if (['error', 'decode_error', 'client_error'].includes(message.type)) failure = JSON.stringify(message); }
    catch (e) { failure = e.message; }
  });
  await until(() => messages.find(m => m.type === 'agents' && m.agents.some(a => a.agent === target.client)), 'listed fixture agent');
  send({ type: 'subscribe', agent: target.client, max_fps: 15, codec: 'h264' });
  await targetState('live', 0);
  await until(() => messages.find(m => m.type === 'keyframe'), 'H.264 keyframe and format');
  results.native.status = 'running';
  for (const [index, rgb] of [[0, [0, .65, .65]], [1, [.8, .2, .1]], [2, [.1, .3, .9]]]) {
    await caseRun(`solid-${index}`, async () => {
      await command('solid', { rgb }); await sleep(500);
      const frame = await snapshot(`solid-${index}`), expected = rgb.map(v => Math.round(v * 255));
      assert.ok(frame.centerRGB.every((v, i) => Math.abs(v - expected[i]) <= 16), JSON.stringify({ frame, expected }));
      return { frame, expected, tolerance: 16 };
    });
  }
  results.native.pixels = 'three solid colors within 16/255 per sRGB channel';
  await caseRun('covered', async () => {
    await command('solid'); await sleep(500);
    const order = latest.windows, index = order.findIndex(w => w.id === fixture.window), w = order[index];
    assert.ok(index >= 0, 'fixture in ordered on-screen list');
    const cover = order.slice(0, index).find(other => other.layer === 0 && !owned.has(other.pid) &&
      other.bounds.X <= w.bounds.X && other.bounds.Y <= w.bounds.Y &&
      other.bounds.X + other.bounds.Width >= w.bounds.X + w.bounds.Width && other.bounds.Y + other.bounds.Height >= w.bounds.Y + w.bounds.Height);
    assert.ok(cover, 'No existing window fully covers the fixture. No user window moved to manufacture coverage.');
    const frame = await snapshot('covered');
    assert.ok(frame.centerRGB.every((v, i) => Math.abs(v - [0,166,166][i]) <= 16));
    return { cover, frame, order };
  });
  for (const [name, restore, state] of [['minimize', 'restore', 'minimized'], ['hide', 'unhide', 'hidden'], ['sharingNone', 'sharingReadOnly', 'hidden_from_capture']]) {
    await caseRun(name, async () => {
      const from = messages.length; await command(name); const changed = await targetState(state, from);
      const restoreFrom = messages.length; await command(restore); await targetState('live', restoreFrom);
      return { changed, restored: await snapshot(`${name}-restored`) };
    });
  }
  await caseRun('resize', async () => {
    await command('resize', { width: 1000, height: 600 }); await sleep(500);
    const frame = await snapshot('resize'); assert.equal(frame.width, 1000); assert.equal(frame.height, 600); return frame;
  });
  for (const [name, close, color] of [['child', 'closeChild', 'magenta'], ['popover', 'closePopover', 'yellow'], ['sheet', 'closeSheet', 'orange']]) {
    await caseRun(name, async () => {
      await command('solid'); await command(name); await sleep(500);
      const frame = await snapshot(name); assert.ok(frame.palettePixels[color] > 0, `${color} surface missing`);
      await command(close); return frame;
    });
  }
  await caseRun('one-off-during-stream', async () => {
    await command('solid'); await sleep(500);
    const path = join(runtime, 'observations', 'stream-one-off.jpg');
    await mkdir(join(runtime, 'observations'), { recursive: true });
    const capture = await helper('captureApplicationSurface', { preview: { kind: 'pid', value: String(fixture.pid), windowIDs: [fixture.window], path } });
    const savedPath = join(dir, 'one-off-during-stream.jpg');
    await writeFile(savedPath, await readFile(path));
    results.native.oneOffPath = savedPath;
    results.native.purplePill = 'unverified: inspect simultaneous one-off and decoded PNG';
    return { capture, path: savedPath, sourcePath: path, decoded: await snapshot('one-off-during-stream') };
  });
  await caseRun('cpu-15fps-animate-20s', async () => {
    await command('animate'); await sleep(500);
    const samples = [cpuSample()], end = performance.now() + 20000;
    while (performance.now() < end) { check(); await sleep(Math.min(1000, end - performance.now())); samples.push(cpuSample()); }
    const first = samples[0], last = samples.at(-1), seconds = (last.at - first.at) / 1000;
    return { seconds, helperCPUPercent: 100 * (last.cpuSeconds - first.cpuSeconds) / seconds, samples };
  });
  await caseRun('close', async () => { const from = messages.length; await command('close'); return targetState('closed', from); });
  await caseRun('release', async () => {
    const from = messages.length; await agent.request('release');
    return until(() => messages.slice(from).find(m => m.type === 'end' && m.reason === 'released'), 'end released');
  });
  const final = JSON.parse(await readFile(fixture.state, 'utf8'));
  assert.ok(!final.foreground_changes.some(c => owned.has(c.to)), 'Owned app activated');
  results.frontmostAfter = latest.frontmost;
  assert.equal(results.frontmostAfter, results.frontmostBefore, 'Frontmost app changed');
  results.finalFixture = final;
  results.native.status = 'passed; visual review pending';
} catch (error) {
  results.error = error.stack; console.error(error.message); process.exitCode = 1;
} finally {
  intentionalCleanup = true;
  // No GUI cleanup or more tool calls after a foreground/safety failure.
  if (!failure && agent.connected) await agent.request('release').catch(() => {});
  agent.close();
  results.frontmostAfter ??= latest?.frontmost;
  for (const pid of owned) {
    try { process.kill(pid, 'SIGTERM'); results.cleanup.push({ pid, signal: 'SIGTERM' }); }
    catch (error) { results.cleanup.push({ pid, error: error.code }); }
  }
  if (runtimeOwned) {
    // The directory was empty at entry. Wait for only our app's descendants to
    // exit, then remove only the named artifacts this run's services create.
    const end = Date.now() + 15000;
    while (Date.now() < end && processes().some(p => p.pid === devPid || p.pid === helperPid || p.parent === devPid)) await sleep(50);
    const expected = new Set(['host-token', 'host.lock', 'host.sock', 'stream.sock', 'host.pid', 'status.json', 'targets.json', 'cursors.json',
      'helper-commands', 'observations', 'control-state.json', 'input-audit.jsonl']);
    results.runtimeCleanup = [];
    for (const name of await readdir(runtime)) {
      if (expected.has(name)) { await rm(join(runtime, name), { recursive: true, force: true }); results.runtimeCleanup.push(name); }
    }
    results.runtimeRemaining = await readdir(runtime);
    if (runtimeCreated && results.runtimeRemaining.length === 0) await rmdir(runtime);
  }
  results.finished = new Date().toISOString(); await save(); console.log(`Evidence: ${dir}`);
}
