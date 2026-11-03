import assert from 'node:assert/strict';
import { execFileSync, spawn } from 'node:child_process';
import { mkdir, readFile, writeFile, rename, realpath, readdir, lstat, rm, rmdir } from 'node:fs/promises';
import { resolve, join } from 'node:path';
import { createInterface } from 'node:readline';
import { parse } from 'yaml';
import { Client } from '../packages/cli/client.mjs';
import { requestComputerUseHelper } from '../packages/engine/computer-use-helper-client.mjs';

if (!process.argv.includes('--interactive')) throw Error('Native stream client check requires --interactive authorization');
const root = await realpath(resolve('.'));
const runtime = '/Users/marioflores/Developer/andrewslab/opencomputeruse/work/p13';
if (process.env.OCU_RUNTIME_DIR && process.env.OCU_RUNTIME_DIR !== runtime) throw Error(`Use only the authorized runtime: ${runtime}`);
process.env.OCU_RUNTIME_DIR = runtime;
const dir = join(root, 'work/stream-client', new Date().toISOString().replaceAll(':', '-'));
await mkdir(dir, { recursive: true, mode: 0o700 });
const app = join(root, 'dist/Open Computer Use.app');
const appBinary = join(app, 'Contents/MacOS/OpenComputerUse');
const fixtureBundle = join(dir, 'StreamFixture.app');
const fixtureState = join(dir, 'fixture.json'), fixtureCommand = join(dir, 'command.json');
const commands = join(runtime, 'helper-commands');
const results = { started: new Date().toISOString(), runtime, clips: [], cleanup: [],
  method: { seconds: 5, fps: 15, toleranceRGB: 16,
    ownChoices: '15 s readiness/cleanup deadlines, 50 ms readiness poll, 100 ms foreground/lock watch, 500 ms fixture settling. Fixture solid sRGB (0,0.65,0.65); 16/255 per-channel tolerance follows the existing native stream check for lossy H.264. ffmpeg tools get a 15 s process deadline. Recordings run in parallel, first by display name and second by id.' } };
const run = (exe, args = []) => execFileSync(exe, args, { encoding: 'utf8', timeout: 15000 }).trim();
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const owned = new Set(), children = new Set(), watchLines = [];
const agent = new Client(runtime);
let failure, cleanup = false, watcher, latest, devPid, helperPid, fixture, runtimeOwned = false, runtimeCreated = false;
const processes = () => run('ps', ['-axo', 'pid=,ppid=,args=']).split('\n').map(line => {
  const m = line.trim().match(/^(\d+)\s+(\d+)\s+(.*)$/); return m && { pid: +m[1], parent: +m[2], args: m[3] };
}).filter(Boolean);
function check() { if (failure) throw Error(failure); }
async function until(fn, label) {
  for (const deadline = Date.now() + 15000; Date.now() < deadline;) {
    check();
    try { const value = await fn(); if (value) return value; }
    catch (error) { if (error.code !== 'ENOENT' && !(error instanceof SyntaxError)) throw error; }
    await sleep(50);
  }
  throw Error(`Timed out: ${label}`);
}
async function helper(action) {
  check(); const result = await requestComputerUseHelper(commands, action, {}, { timeoutMs: 15000 }); check();
  assert.equal(result.success, true, result.error); return JSON.parse(result.stdout);
}
async function command(name) {
  check(); const id = `${Date.now()}-${name}`;
  await writeFile(fixtureCommand + '.tmp', JSON.stringify({ id, command: name }));
  await rename(fixtureCommand + '.tmp', fixtureCommand);
  const state = await until(async () => { const state = JSON.parse(await readFile(fixtureState, 'utf8')); return state.last_command === id && state; }, name);
  assert.equal(state.command_error, null); assert.equal(state.active, false); return state;
}
function start(exe, args, label, options = {}) {
  const child = spawn(exe, args, { stdio: ['ignore', 'pipe', 'pipe'], ...options });
  owned.add(child.pid); children.add(child);
  let stdout = '', stderr = '';
  child.stdout.on('data', data => { stdout += data; }); child.stderr.on('data', data => { stderr += data; });
  const done = new Promise((resolve, reject) => {
    child.once('error', reject);
    child.once('exit', (code, signal) => code === 0 ? resolve({ stdout, stderr }) : reject(Error(`${label} exited ${code ?? signal}: ${stderr}`)));
  });
  done.catch(error => { if (!cleanup) failure ??= error.message; });
  return { child, done };
}

// Read-only diagnostic: observes lock and activation events, never sends input.
const probeSource = String.raw`import AppKit
import CoreGraphics
func emit(_ value: [String: Any]) { print(String(data: try! JSONSerialization.data(withJSONObject: value), encoding: .utf8)!); fflush(stdout) }
func locked() -> Bool? {
    guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return nil }
    return session["CGSSessionScreenIsLocked"] as? Bool ?? false
}
if CommandLine.arguments[1] == "--session" { emit(["locked": locked() as Any? ?? NSNull()]); exit(0) }
let bundles = Array(CommandLine.arguments.dropFirst(2))
func observe() {
    let front = NSWorkspace.shared.frontmostApplication
    let path = front?.executableURL?.path ?? ""
    let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
    emit(["locked": locked() as Any? ?? NSNull(), "frontmost": front?.processIdentifier ?? 0,
          "owned": bundles.contains { path.hasPrefix($0 + "/Contents/") },
          "windows": windows.map { ["id": $0[kCGWindowNumber as String] ?? 0, "bounds": $0[kCGWindowBounds as String] ?? [:]] }])
}
NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { _ in observe() }
observe(); Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in observe() }; RunLoop.main.run()
`;

try {
  run('ffprobe', ['-version']); run('ffmpeg', ['-version']);
  assert.ok(Buffer.byteLength(join(runtime, 'stream.sock')) + 1 <= 104, 'Runtime exceeds Darwin socket path limit');
  assert.ok(!processes().some(p => p.args === appBinary), 'This worktree dev app is already running; refusing to take ownership');
  await lstat(appBinary);
  try {
    const stat = await lstat(runtime);
    assert.ok(stat.isDirectory() && !stat.isSymbolicLink() && (stat.mode & 0o777) === 0o700, 'Runtime must be a real mode-0700 directory');
    assert.deepEqual(await readdir(runtime), [], 'Refusing a nonempty runtime; another run may own it');
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
    await mkdir(runtime, { mode: 0o700 }); runtimeCreated = true;
  }
  runtimeOwned = true;
  const probe = join(dir, 'session-probe'), source = join(dir, 'session-probe.swift');
  await writeFile(source, probeSource); run('xcrun', ['swiftc', source, '-o', probe]);
  results.session = JSON.parse(run(probe, ['--session']));
  assert.equal(results.session.locked, false, 'Mac session locked or unavailable; no apps launched');
  watcher = start(probe, ['--watch', app, fixtureBundle], 'foreground/lock watcher');
  createInterface({ input: watcher.child.stdout }).on('line', line => {
    try {
      latest = JSON.parse(line); watchLines.push(latest);
      if (latest.owned || latest.locked !== false) {
        failure ??= latest.owned ? `Owned app came to front: ${latest.frontmost}` : 'Mac session locked or unavailable';
        for (const child of children) if (child !== watcher.child && child.exitCode === null) child.kill('SIGTERM');
      }
    } catch (error) { failure ??= error.message; }
  });
  await until(() => latest, 'foreground/lock watcher'); results.frontmostBefore = latest.frontmost;
  run('open', ['-g', '-n', '--env', `OCU_RUNTIME_DIR=${runtime}`, app]);
  devPid = (await until(() => processes().find(p => p.args === appBinary), 'dev app')).pid; owned.add(devPid);
  helperPid = (await until(() => processes().find(p => p.parent === devPid && p.args.includes('--command-directory ' + commands)), 'dev helper')).pid;
  owned.add(helperPid); results.processes = { devPid, helperPid };
  results.permissions = await helper('permissionStatus');
  for (const name of ['Accessibility', 'Screen Recording']) assert.ok(results.permissions.find(p => p.name === name)?.isGranted, `${name} is not granted; stopped without requesting permissions`);
  await until(async () => { await readFile(join(runtime, 'host-token')); return processes().some(p => p.parent === devPid && p.args.includes('ocu-host')); }, 'dev host');
  await until(async () => (await lstat(join(runtime, 'stream.sock'))).isSocket(), 'stream socket');
  await mkdir(join(fixtureBundle, 'Contents/MacOS'), { recursive: true });
  run('xcrun', ['swiftc', 'tests/native-fixtures/StreamFixture.swift', '-o', join(fixtureBundle, 'Contents/MacOS/StreamFixture')]);
  await writeFile(join(fixtureBundle, 'Contents/Info.plist'), `<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleName</key><string>OCU Stream Fixture</string><key>CFBundleExecutable</key><string>StreamFixture</string><key>CFBundleIdentifier</key><string>com.andrewslabmd.opencomputeruse.streamfixture</string><key>CFBundlePackageType</key><string>APPL</string><key>LSUIElement</key><true/></dict></plist>`);
  run('open', ['-g', '-n', fixtureBundle, '--args', fixtureState, fixtureCommand]);
  fixture = await until(async () => JSON.parse(await readFile(fixtureState, 'utf8')), 'stream fixture'); owned.add(fixture.pid);
  assert.equal(fixture.active, false, 'Fixture activated at launch');
  assert.ok(!fixture.foreground_changes.some(c => owned.has(c.to)), 'Owned app activated during fixture launch');
  await until(() => latest.windows.find(w => w.id === fixture.window && w.bounds.Width > 0), 'fixture window');
  results.fixture = await command('solid'); await sleep(500); check();
  // CGWindow bounds animate at launch; compare to the fixture's final NSWindow frame.
  const window = await until(() => latest.windows.find(w => w.id === fixture.window &&
    w.bounds.Width === results.fixture.frame[2] && w.bounds.Height === results.fixture.frame[3]), 'settled fixture window');
  results.window = window;
  await agent.connect('Stream client acceptance');
  const observed = await agent.request('tools/call', { name: 'use_observe', arguments: { app_target: `PID:${fixture.pid}` } }); check();
  assert.notEqual(observed.isError, true, JSON.stringify(observed));
  assert.ok(parse(observed.content.find(c => c.type === 'text').text).snapshot, 'Fixture observation succeeded');
  const target = await until(async () => JSON.parse(await readFile(join(runtime, 'targets.json'), 'utf8')).find(t => t.pid === fixture.pid), 'observed fixture target');
  results.agent = target.client;
  const paths = [join(dir, 'one.h264'), join(dir, 'two.h264')];
  const cli = join(app, 'Contents/MacOS/ocu');
  const clients = paths.map((out, i) => start(cli, ['stream', '--agent', i === 0 ? 'Stream client acceptance' : target.client, '--out', out, '--seconds', '5', '--fps', '15'], `stream client ${i + 1}`, { env: { ...process.env, OCU_RUNTIME_DIR: runtime } }));
  results.clients = await Promise.all(clients.map(c => c.done)); check();
  for (const [index, path] of paths.entries()) {
    const output = run('ffprobe', ['-v', 'error', '-count_frames', '-show_entries', 'stream=codec_name,width,height,nb_read_frames', '-of', 'json', path]);
    console.log(`${path}\n${output}`);
    const info = JSON.parse(output), stream = info.streams[0];
    results.clips.push({ path, ffprobe: info });
    assert.equal(stream.codec_name, 'h264'); assert.equal(stream.width, window.bounds.Width); assert.equal(stream.height, window.bounds.Height); assert.ok(+stream.nb_read_frames > 0);
    const png = join(dir, `frame-${index + 1}.png`);
    run('ffmpeg', ['-v', 'error', '-i', path, '-frames:v', '1', png]);
    const pixel = execFileSync('ffmpeg', ['-v', 'error', '-i', png, '-vf', `format=rgb24,crop=1:1:${Math.floor(stream.width / 2)}:${Math.floor(stream.height / 2)}`, '-frames:v', '1', '-f', 'rawvideo', '-pix_fmt', 'rgb24', 'pipe:1'], { timeout: 15000 });
    const expected = results.fixture.colour.map(v => Math.round(v * 255));
    assert.equal(pixel.length, 3); assert.ok([...pixel].every((v, i) => Math.abs(v - expected[i]) <= 16), `Decoded center ${[...pixel]} differs from fixture ${expected}`);
    Object.assign(results.clips[index], { png, centerRGB: [...pixel], expectedRGB: expected }); check();
  }
  results.finalFixture = JSON.parse(await readFile(fixtureState, 'utf8'));
  assert.equal(results.finalFixture.active, false);
  assert.ok(!results.finalFixture.foreground_changes.some(c => owned.has(c.to)), 'Owned app activated');
  results.status = 'passed: two concurrent JavaScript clients, H.264 dimensions/frame counts and fixture color';
} catch (error) {
  results.error = error.stack; console.error(error.message); process.exitCode = 1;
} finally {
  cleanup = true;
  if (!failure && agent.connected) await agent.request('release').catch(() => {});
  agent.close(); results.frontmostAfter = latest?.frontmost;
  // Retain only descendants of the app launched by this run, never unrelated services.
  const snapshot = processes();
  if (devPid) {
    const descendants = new Set([devPid]);
    for (let changed = true; changed;) {
      changed = false;
      for (const p of snapshot) if (descendants.has(p.parent) && !descendants.has(p.pid)) { descendants.add(p.pid); changed = true; }
    }
    for (const pid of descendants) owned.add(pid);
  }
  for (const pid of owned) {
    if (!snapshot.some(p => p.pid === pid)) continue;
    try { process.kill(pid, 'SIGTERM'); results.cleanup.push({ pid, signal: 'SIGTERM' }); }
    catch (error) { results.cleanup.push({ pid, error: error.code }); }
  }
  if (runtimeOwned) {
    const deadline = Date.now() + 15000;
    while (Date.now() < deadline && processes().some(p => owned.has(p.pid))) await sleep(50);
    if (processes().some(p => owned.has(p.pid))) results.runtimeCleanup = 'Owned processes still running; runtime retained';
    else {
      const expected = new Set(['host-token', 'host.lock', 'host.sock', 'stream.sock', 'host.pid', 'status.json', 'targets.json', 'cursors.json', 'helper-commands', 'observations', 'control-state.json', 'input-audit.jsonl', 'capture-mode.json']);
      for (const name of await readdir(runtime)) if (expected.has(name)) await rm(join(runtime, name), { recursive: true, force: true });
      results.runtimeRemaining = await readdir(runtime);
      if (runtimeCreated && results.runtimeRemaining.length === 0) await rmdir(runtime);
    }
  }
  results.safetyFailure = failure; results.finished = new Date().toISOString();
  await writeFile(join(dir, 'results.json'), JSON.stringify(results, null, 2));
  await writeFile(join(dir, 'windows.jsonl'), watchLines.map(row => JSON.stringify(row)).join('\n') + '\n');
  console.log(`Evidence: ${dir}`);
}
