import assert from 'node:assert/strict';
import { execFileSync, spawn } from 'node:child_process';
import { appendFileSync, readFileSync } from 'node:fs';
import { mkdir, readFile, writeFile, realpath, readdir, lstat, rm, rmdir } from 'node:fs/promises';
import { resolve, join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { createInterface } from 'node:readline';
import { parse, stringify } from 'yaml';
import { Client } from '../packages/cli/client.mjs';
import { requestComputerUseHelper } from '../packages/engine/computer-use-helper-client.mjs';

// The existing native suites inspect complete models. The documented wire
// encoding uses prior node IDs and unchanged-window stubs after actions. Decode
// those references locally; never add an observation, action, delay or retry.
export function expandNativeSnapshot(previous, current) {
  const delta = current.changes_since !== undefined;
  if (delta) {
    assert.equal(current.changes_since, previous?.observation, 'Native delta has no exact delivered base');
    assert.equal(current.application?.pid, previous?.application?.pid, 'Native delta crossed processes');
  }
  const nodes = new Map(), windows = new Map();
  function index(node) {
    assert.ok(node && typeof node === 'object', 'Delta base must already be expanded');
    nodes.set(node.id, node);
    for (const child of node.children ?? []) index(child);
  }
  if (delta) for (const window of previous.surface?.windows ?? []) { windows.set(window.window_id, window); index(window.tree); }
  function expand(node) {
    if (typeof node === 'string' || typeof node === 'number') {
      assert.ok(delta && nodes.has(node), `Unknown native node reference: ${node}`);
      return structuredClone(nodes.get(node));
    }
    assert.ok(node && typeof node === 'object', 'Native window tree missing');
    return { ...node, ...(node.children ? { children: node.children.map(expand) } : {}) };
  }
  return { ...current, ...(current.surface ? { surface: { ...current.surface,
    windows: (current.surface.windows ?? []).map(window => {
      if (window.unchanged) {
        assert.ok(delta && windows.has(window.window_id), `Unknown native window reference: ${window.window_id}`);
        return structuredClone(windows.get(window.window_id));
      }
      return { ...window, tree: expand(window.tree) };
    }) } } : {}) };
}
if (process.env.OCU_NATIVE_EXPAND_SNAPSHOTS === '1') {
  const delivered = new WeakMap(), request = Client.prototype.request;
  Client.prototype.request = async function(method, params, extra) {
    const raw = await request.call(this, method, params, extra);
    if (method === 'release') delivered.delete(this);
    if (method !== 'tools/call' || !['use_observe', 'use_action_batch'].includes(params?.name)) return raw;
    let expanded = false;
    const content = raw.content?.map(block => {
      if (block.type !== 'text') return block;
      const payload = parse(block.text);
      if (!payload?.snapshot) return block;
      if (process.env.OCU_NATIVE_RAW_SNAPSHOTS) appendFileSync(process.env.OCU_NATIVE_RAW_SNAPSHOTS,
        JSON.stringify({ tool: params.name, snapshot: payload.snapshot, metadata: raw._meta }) + '\n');
      payload.snapshot = expandNativeSnapshot(delivered.get(this), payload.snapshot);
      delivered.set(this, payload.snapshot); expanded = true;
      return { ...block, text: stringify(payload) };
    });
    if (params.name === 'use_observe' && !expanded) delivered.delete(this);
    return { ...raw, ...(content ? { content } : {}) };
  };
}

export const sleep = ms => new Promise(r => setTimeout(r, ms));
const run = (exe, args = []) => execFileSync(exe, args, { encoding: 'utf8' }).trim();
const processes = () => run('ps', ['-axo', 'pid=,ppid=,args=']).split('\n').map(line => {
  const m = line.trim().match(/^(\d+)\s+(\d+)\s+(.*)$/);
  return m && { pid: +m[1], parent: +m[2], args: m[3] };
}).filter(Boolean);
export const fixturePlist = name => `<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleName</key><string>${name}</string><key>CFBundleExecutable</key><string>${name}</string><key>CFBundleIdentifier</key><string>com.andrewslabmd.opencomputeruse.${name.toLowerCase()}</string><key>CFBundlePackageType</key><string>APPL</string><key>LSUIElement</key><true/></dict></plist>`;

// The runner watches the registered bundles from before open -g, including
// fixtures whose state file has not been written yet. Never adopt existing apps.
const launchedFixtureBundles = new Set();
export function openNativeFixture(app, args) {
  app = resolve(app);
  // The agents suite deliberately opens two independent instances of its one
  // freshly built bundle. Refuse an existing instance only at the first launch;
  // subsequent open -g -n calls in this process launch additional owned instances.
  if (!launchedFixtureBundles.has(app)) {
    assert.ok(!processes().some(p => p.args.startsWith(app + '/Contents/MacOS/')), 'Fixture already running before this harness launched it');
    if (process.env.OCU_NATIVE_BUNDLES) appendFileSync(process.env.OCU_NATIVE_BUNDLES, app + '\n');
    launchedFixtureBundles.add(app);
  }
  execFileSync('open', ['-g', '-n', app, '--args', ...args]);
}
export async function launchNativeFixture(app, args, statePath) {
  openNativeFixture(app, args);
  for (const by = Date.now() + 10000; Date.now() < by;) {
    try {
      const state = JSON.parse(await readFile(statePath, 'utf8'));
      const match = processes().find(p => p.pid === state.pid && p.args.startsWith(app + '/Contents/MacOS/'));
      if (match) return {
        pid: state.pid,
        get exitCode() { return processes().some(p => p.pid === state.pid && p.args === match.args) ? null : 0; },
        kill(signal = 'SIGTERM') { if (this.exitCode === null) process.kill(this.pid, signal); },
      };
    } catch (e) { if (e.code !== 'ENOENT' && !(e instanceof SyntaxError)) throw e; }
    await sleep(50);
  }
  throw Error('Fixture launch state timed out');
}

// This executable is a diagnostic, never an app binary. It observes activation
// notifications as well as 100 ms samples and checks the lock on every sample.
const probeSource = String.raw`import AppKit
import CoreGraphics
import ImageIO
func emit(_ value: [String: Any]) { print(String(data: try! JSONSerialization.data(withJSONObject: value), encoding: .utf8)!); fflush(stdout) }
func locked() -> Bool? {
    guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return nil }
    return session["CGSSessionScreenIsLocked"] as? Bool ?? false
}
let args = CommandLine.arguments
if args[1] == "--session" { emit(["locked": locked() as Any? ?? NSNull()]); exit(0) }
if args[1] == "--watch" {
    let registry = args[2]
    func watch(_ source: String) {
        let front = NSWorkspace.shared.frontmostApplication
        let path = front?.executableURL?.path ?? ""
        let bundles = (try? String(contentsOfFile: registry, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
        var value: [String: Any] = ["at": Date().timeIntervalSince1970, "frontmost": front?.processIdentifier ?? 0,
              "owned": bundles.contains { path.hasPrefix($0 + "/Contents/") }, "locked": locked() as Any? ?? NSNull(), "source": source]
        if let data = try? Data(contentsOf: URL(fileURLWithPath: args[3])),
           let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
          value["monitor"] = config
          var fixtureSamples: [[String: Any]] = []
          for item in config["fixtures"] as? [[String: Any]] ?? [config] {
            guard let pid = item["pid"] as? Int, let window = item["window"] as? Int else { continue }
            var sample: [String: Any] = ["pid": pid, "window": window]
            let all = (CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []).filter { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.intValue == pid }
            let windows = all.map { w -> [String: Any] in ["id": w[kCGWindowNumber as String] ?? 0, "title": w[kCGWindowName as String] ?? NSNull(), "bounds": w[kCGWindowBounds as String] ?? [:], "onscreen": w[kCGWindowIsOnscreen as String] ?? false] }
            let targetBounds = all.first { ($0[kCGWindowNumber as String] as? NSNumber)?.intValue == window }?[kCGWindowBounds as String] as? [String: Double]
            let indicators = windows.filter { w in
                guard w["title"] as? String == "Window", w["onscreen"] as? Bool == true,
                      let bounds = w["bounds"] as? [String: Double], let target = targetBounds,
                      let x = bounds["X"], let y = bounds["Y"], let width = bounds["Width"], let height = bounds["Height"],
                      let tx = target["X"], let ty = target["Y"] else { return false }
                return abs(width - 66) <= 4 && abs(height - 20) <= 4 && x >= tx && x <= tx + 100 && y >= ty && y <= ty + 32
            }
            sample["fixtureWindows"] = windows
            sample["indicatorPresent"] = !indicators.isEmpty; sample["indicators"] = indicators
            if let data = try? Data(contentsOf: URL(fileURLWithPath: args[4] + "/targets.json")),
               let targets = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                sample["helperTargets"] = targets.filter { ($0["pid"] as? NSNumber)?.intValue == pid }
            } else { sample["helperTargets"] = NSNull() }
            fixtureSamples.append(sample)
          }
          value["fixtures"] = fixtureSamples
          if fixtureSamples.count == 1 { for (key, item) in fixtureSamples[0] { value[key] = item } }
        }
        emit(value)
    }
    NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { _ in watch("activation") }
    watch("initial"); Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in watch("timer") }; RunLoop.main.run()
} else if args[1] == "--decode" {
    let url = URL(fileURLWithPath: args[2])
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fatalError("Invalid JPEG") }
    let w = image.width, h = image.height, space = CGColorSpace(name: CGColorSpace.sRGB)!
    var pixels = [UInt8](repeating: 0, count: w * h * 4)
    var center: [UInt8] = [], purple = 0, grey = 0
    pixels.withUnsafeMutableBytes { bytes in
        let ctx = CGContext(data: bytes.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let data = bytes.bindMemory(to: UInt8.self)
        let middle = ((h / 2) * w + w / 2) * 4
        center = [data[middle], data[middle+1], data[middle+2]]
        // Window captures are point-resolution. Top-left title-bar ROI excludes
        // the traffic-light centers and includes the purple pill's right half.
        for y in 3..<min(24, h) { for x in 8..<min(90, w) {
            let p = (y * w + x) * 4, r = Int(data[p]), g = Int(data[p+1]), b = Int(data[p+2])
            if b > 140 && b - r > 35 && b - g > 35 { purple += 1 }
            if max(r,g,b) - min(r,g,b) <= 16 && r < 140 { grey += 1 }
        }}
        if args.count > 3 {
            let out = URL(fileURLWithPath: args[3])
            let dest = CGImageDestinationCreateWithURL(out as CFURL, "public.png" as CFString, 1, nil)!
            CGImageDestinationAddImage(dest, ctx.makeImage()!, nil); precondition(CGImageDestinationFinalize(dest))
        }
    }
    emit(["width": w, "height": h, "centerRGB": center, "purplePixels": purple, "greyPixels": grey])
}
`;

export async function createNativeRun(kind, { outputGroup = 'stream-phase2' } = {}) {
  assert.ok(process.argv.includes('--interactive'), 'Native checks require --interactive authorization');
  const root = await realpath(resolve('.'));
  const dir = join(root, 'work', outputGroup, new Date().toISOString().replaceAll(':', '-'));
  await mkdir(dir, { recursive: true, mode: 0o700 });
  const runtime = '/Users/marioflores/Developer/andrewslab/opencomputeruse/work/p13';
  assert.ok(!process.env.OCU_RUNTIME_DIR || resolve(process.env.OCU_RUNTIME_DIR) === runtime, 'Only the approved isolated work/p13 runtime is allowed');
  process.env.OCU_RUNTIME_DIR = runtime;
  const results = { kind, started: new Date().toISOString(), runtime, modes: [], cleanup: [],
    method: { clicksPerMode: 100, toleranceRGB: 16, pillPollMs: 250, pillTargetMs: 2000, windowPollMs: 100,
      indicatorWindowMatch: { title: 'Window', sizePoints: [66, 20], sizeTolerancePoints: 4, topLeftOffsetPoints: { x: [0, 100], y: [0, 32] } },
      ownChoices: 'Indicator match uses +/-4 pt size tolerance and title-top-left x 0..100, y 0..32 pt; only fixture PID windows are retained. Helper start count is inferred from target main-window activation intervals and indicator appearances, not an internal SCStream counter; restarts shorter than 100 ms are unverified. Live setup waits for its first indicator before the 100-iteration measurement; no waits are added between click and observation. 15 s service readiness, 50 ms readiness polls; 10 s fixture readiness. Activation notification plus 100 ms foreground/lock sampling. JPEG sRGB center pixel; title ROI x=8..<90, y=3..<24 from top-left (point-resolution). Violet pill = b>140 and b-r,b-g>35 (corrected from a magenta predicate after visual review of macOS 27’s blue-violet pill); absent = 0 purple pixels and >=1 dark grey pixel (channel spread <=16, r<140). Require at least one live-sourced image to establish that live capture was exercised; require purple in live pre-release baseline to validate disappearance. Latency is complete use_observe round trip (AX + JPEG + IPC), excludes local decode; median averages middle pair, p95 nearest rank. Pill timing from release request dispatch, upper bound is capture response, deadline 2 s; no deliberate action delay, task retries or relaxed checks.' },
    excludedSuites: { basic: 'Not run: ComputerUseFixture deliberately activates apps and requires Mario’s idle gate', finder: 'Not run: drives Mario’s Finder and exposes his files', selection: 'Not run: drives Mario’s Finder and exposes his files' } };
  const commands = join(runtime, 'helper-commands');
  const monitorPath = join(dir, 'window-watch.json');
  const probe = join(dir, 'native-probe'), registry = join(dir, 'owned-bundles.txt');
  const app = join(root, 'dist/Open Computer Use.app'), appBinary = join(app, 'Contents/MacOS/OpenComputerUse');
  let failure, runtimeOwned = false, runtimeCreated = false, watcher, devPid, helperPid, cleanupStarted = false;
  const owned = new Set(), watch = [], baseline = new Set(processes().map(p => p.pid));
  const context = { root, dir, runtime, commands, results, probe, owned, watch, monitorPath,
    check() { if (failure) throw Error(failure); },
    async until(fn, label) {
      for (const by = Date.now() + 15000; Date.now() < by;) {
        context.check();
        try { const value = await fn(); if (value) return value; }
        catch (e) { if (e.code !== 'ENOENT' && !(e instanceof SyntaxError)) throw e; }
        await sleep(50);
      }
      throw Error(`Timed out: ${label}`);
    },
    async helper(action, payload = {}) {
      context.check();
      const response = await requestComputerUseHelper(commands, action, payload, { timeoutMs: 35000 });
      context.check(); assert.equal(response.success, true, response.error);
      return JSON.parse(response.stdout);
    },
    decode(path, png) { context.check(); return JSON.parse(run(probe, ['--decode', path, ...(png ? [png] : [])])); },
    async save() {
      results.frontmostAfter = watch.at(-1)?.frontmost;
      results.userSwitches = watch.filter((row, i) => i > 0 && row.frontmost !== watch[i-1].frontmost);
      await writeFile(join(dir, 'results.json'), JSON.stringify(results, null, 2));
      await writeFile(join(dir, 'foreground.jsonl'), watch.map(row => JSON.stringify(row)).join('\n') + '\n');
      await writeFile(join(dir, 'report.md'), ['# Phase 2 native check', '',
        `Kind: ${kind}. Status: ${results.error || results.status || 'running'}`, '',
        ...results.modes.map(mode => `- ${mode.mode}: ${JSON.stringify({ ...mode, samples: mode.samples ? `${mode.samples.length} rows in results.json` : undefined })}`), '',
        `Method: ${JSON.stringify(results.method)}`, '',
        'Suite snapshot deltas are expanded locally against their exact delivered base; raw snapshots are retained, and no tool calls or retries are added. Basic suite excluded: its fixture deliberately activates apps and needs Mario’s idle gate. Finder and selection excluded: they drive Mario’s Finder and expose his files.', '',
        `Cleanup: ${JSON.stringify(results.cleanup)}. Runtime remaining: ${JSON.stringify(results.runtimeRemaining)}`, '',
        'Development-component native checks only; not public release acceptance. Sample image visual review is recorded separately after inspection.', ''].join('\n'));
    },
    async cleanup() {
      cleanupStarted = true;
      // Include only descendants of our launch and bundles registered before our open -g.
      const bundles = readFileSync(registry, 'utf8').trim().split('\n').filter(Boolean);
      const list = processes();
      // A process may have exited during a long suite; do not signal a reused PID.
      for (const pid of owned) if (!list.some(p => p.pid === pid && (p.args.startsWith(probe) || bundles.some(bundle => p.args.startsWith(bundle + '/Contents/'))))) owned.delete(pid);
      for (const p of list) if (!baseline.has(p.pid) && bundles.some(bundle => p.args.startsWith(bundle + '/Contents/'))) owned.add(p.pid);
      for (let changed = true; changed;) {
        changed = false;
        for (const p of list) if (!baseline.has(p.pid) && owned.has(p.parent) && !owned.has(p.pid)) { owned.add(p.pid); changed = true; }
      }
      for (const pid of owned) {
        try { process.kill(pid, 'SIGTERM'); results.cleanup.push({ pid, signal: 'SIGTERM' }); }
        catch (e) { if (e.code !== 'ESRCH') results.cleanup.push({ pid, error: e.code }); }
      }
      if (runtimeOwned) {
        for (const by = Date.now() + 15000; Date.now() < by && processes().some(p => owned.has(p.pid));) await sleep(50);
        assert.ok(!processes().some(p => owned.has(p.pid)), 'Owned processes still running; runtime retained');
        const expected = new Set(['host-token', 'host.lock', 'host.sock', 'stream.sock', 'host.pid', 'status.json', 'targets.json', 'cursors.json', 'helper-commands', 'observations', 'control-state.json', 'input-audit.jsonl', 'capture-mode.json']);
        for (const name of await readdir(runtime)) if (expected.has(name)) await rm(join(runtime, name), { recursive: true, force: true });
        results.runtimeRemaining = await readdir(runtime);
        assert.deepEqual(results.runtimeRemaining, [], 'Unexpected runtime artifacts retained');
        if (runtimeCreated) await rmdir(runtime);
      }
      results.finished = new Date().toISOString();
      await context.save(); console.log(`Evidence: ${dir}`);
    },
  };
  function stopForSafety() {
    context.onSafety?.();
    const bundles = readFileSync(registry, 'utf8').trim().split('\n').filter(Boolean);
    const list = processes(), terminate = new Set();
    for (const p of list) if (!baseline.has(p.pid) && bundles.some(bundle => p.args.startsWith(bundle + '/Contents/'))) terminate.add(p.pid);
    for (let changed = true; changed;) {
      changed = false;
      for (const p of list) if (!baseline.has(p.pid) && terminate.has(p.parent) && !terminate.has(p.pid)) { terminate.add(p.pid); changed = true; }
    }
    for (const pid of terminate) { owned.add(pid); try { process.kill(pid, 'SIGTERM'); } catch (e) { if (e.code !== 'ESRCH') results.cleanup.push({ pid, error: e.code }); } }
  }
  await writeFile(registry, '');
  try {
    assert.ok(Buffer.byteLength(join(runtime, 'stream.sock')) + 1 <= 104, 'Unix socket path too long');
    assert.ok(!processes().some(p => p.args === appBinary), 'Dev app already running; refusing to adopt it');
    await writeFile(join(dir, 'native-probe.swift'), probeSource);
    run('xcrun', ['swiftc', join(dir, 'native-probe.swift'), '-o', probe]);
    results.session = JSON.parse(run(probe, ['--session']));
    assert.equal(results.session.locked, false, 'Mac session locked or unavailable; no apps launched');
    try {
      const stat = await lstat(runtime);
      assert.ok(stat.isDirectory() && !stat.isSymbolicLink() && stat.uid === process.getuid() && (stat.mode & 0o777) === 0o700, 'Runtime must be a user-owned mode-0700 real directory');
      assert.deepEqual(await readdir(runtime), [], 'Refusing nonempty runtime');
    } catch (e) { if (e.code !== 'ENOENT') throw e; await mkdir(runtime, { mode: 0o700 }); runtimeCreated = true; }
    runtimeOwned = true;
    process.env.OCU_NATIVE_BUNDLES = registry;
    watcher = spawn(probe, ['--watch', registry, monitorPath, runtime], { stdio: ['ignore', 'pipe', 'pipe'] }); owned.add(watcher.pid);
    watcher.on('error', e => { failure = `Foreground watcher failed: ${e.message}`; stopForSafety(); });
    watcher.on('exit', code => { if (!cleanupStarted) { failure = `Foreground watcher exited: ${code}`; stopForSafety(); } });
    watcher.stderr.on('data', data => { (results.watcherStderr ??= []).push(String(data)); });
    createInterface({ input: watcher.stdout }).on('line', line => {
      try {
        const row = JSON.parse(line); watch.push(row);
        if (row.owned || row.locked !== false) {
          failure ??= row.owned ? `Owned app came to front: ${row.frontmost}` : 'Mac session locked or unavailable';
          stopForSafety();
        }
      } catch (e) { failure = e.message; stopForSafety(); }
    });
    await context.until(() => watch.length, 'foreground watcher');
    results.frontmostBefore = watch[0].frontmost;
    appendFileSync(registry, app + '\n');
    run('open', ['-g', '-n', '--env', `OCU_RUNTIME_DIR=${runtime}`, app]);
    devPid = (await context.until(() => processes().find(p => p.args === appBinary), 'dev app')).pid; owned.add(devPid);
    helperPid = (await context.until(() => processes().find(p => p.parent === devPid && p.args.includes('--command-directory ' + commands)), 'dev helper')).pid; owned.add(helperPid);
    results.processes = { devPid, helperPid };
    results.permissions = await context.helper('permissionStatus');
    for (const name of ['Screen Recording', 'Accessibility']) assert.ok(results.permissions.find(p => p.name === name)?.isGranted, `${name} missing; no permission requested`);
    await context.until(async () => { await readFile(join(runtime, 'host-token')); return processes().some(p => p.parent === devPid && p.args.includes('ocu-host')); }, 'dev host');
    return context;
  } catch (e) {
    results.error = e.stack; await context.cleanup(); throw e;
  }
}

async function main() {
  const allowedSuites = ['native-agents', 'native-clicks', 'native-interaction', 'native-observation', 'native-overlay'];
  const selection = process.argv.find(arg => arg.startsWith('--suites='));
  const suites = selection ? selection.slice('--suites='.length).split(',').map(name => name.startsWith('native-') ? name : 'native-' + name) : allowedSuites;
  const modeSelection = process.argv.find(arg => arg.startsWith('--modes='));
  const modes = modeSelection ? modeSelection.slice('--modes='.length).split(',') : ['live', 'screenshots'];
  assert.ok(suites.length && new Set(suites).size === suites.length && suites.every(name => allowedSuites.includes(name)), 'Only the five authorized native suites may be selected');
  assert.ok(modes.length && new Set(modes).size === modes.length && modes.every(mode => ['live', 'screenshots'].includes(mode)), 'Invalid capture mode selection');
  const ctx = await createNativeRun('existing suites in selected modes');
  // Every suite receives the isolated runtime through the inherited environment.
  let child;
  ctx.onSafety = () => { child?.kill('SIGTERM'); };
  try {
    ctx.results.modes = modes.map(mode => ({ mode, suites: suites.map(suite => ({ suite: `scripts/test-${suite}.mjs`, status: 'not run' })) }));
    for (const row of ctx.results.modes) {
      const { mode } = row;
      assert.equal((await ctx.helper('setCaptureMode', { mode })).mode, mode);
      for (const suite of suites) {
        ctx.check();
        const path = `scripts/test-${suite}.mjs`, started = performance.now();
        const result = row.suites.find(result => result.suite === path);
        result.command = `OCU_RUNTIME_DIR=${ctx.runtime} node ${path} --interactive`;
        const log = [];
        child = spawn(process.execPath, [path, '--interactive'], { env: { ...process.env, OCU_NATIVE_EXPAND_SNAPSHOTS: '1', OCU_NATIVE_RAW_SNAPSHOTS: join(ctx.dir, `${mode}-${suite}-raw-snapshots.jsonl`) }, stdio: ['ignore', 'pipe', 'pipe'] });
        ctx.owned.add(child.pid);
        for (const stream of [child.stdout, child.stderr]) stream.on('data', data => { log.push(data.toString()); process.stdout.write(data); });
        const exit = await new Promise((res, rej) => { child.once('error', rej); child.once('exit', (code, signal) => res({ code, signal })); });
        ctx.owned.delete(child.pid); child = undefined;
        Object.assign(result, exit, { elapsedMs: performance.now() - started, status: exit.code === 0 ? 'passed' : 'failed' });
        await writeFile(join(ctx.dir, `${mode}-${suite}.log`), log.join(''));
        await ctx.save(); ctx.check();
        // Any native/product failure stops further input immediately.
        if (exit.code !== 0) throw Error(`${mode} ${suite} failed (${exit.code}); stopped without product fixes`);
      }
    }
    ctx.results.status = 'passed';
  } catch (e) { ctx.results.error = e.stack; process.exitCode = 1; console.error(e.message); }
  finally { await ctx.cleanup(); }
}
if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) await main();
