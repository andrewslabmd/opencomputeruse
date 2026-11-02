import { execFileSync, spawn } from 'node:child_process';
import { mkdir, readFile, writeFile, rename, readdir, rm } from 'node:fs/promises';
import { resolve, join, isAbsolute } from 'node:path';
import { createInterface } from 'node:readline';
import { loadavg, cpus } from 'node:os';
import { requestComputerUseHelper } from '../packages/engine/computer-use-helper-client.mjs';

if (!process.argv.includes('--interactive')) throw Error('Native stream measurements require --interactive authorization');
const root = resolve('.');
const runtime = process.env.OCU_RUNTIME_DIR;
if (!runtime || !isAbsolute(runtime) || !runtime.startsWith(join(root, 'work/'))) throw Error('Set an absolute OCU_RUNTIME_DIR inside this worktree/work');
const dir = resolve(`work/stream-phase0/${new Date().toISOString().replaceAll(':', '-')}`);
await mkdir(dir, { recursive: true, mode: 0o700 });
const commands = join(runtime, 'helper-commands');
const sleep = ms => new Promise(r => setTimeout(r, ms));
const run = (exe, args = []) => execFileSync(exe, args, { encoding: 'utf8' }).trim();
const results = { started: new Date().toISOString(), runtime, machine: { os: run('sw_vers'), arch: run('uname', ['-m']), logicalCPUs: cpus().length, power: run('pmset', ['-g', 'batt']) },
  measurements: [], answers: Object.fromEntries(Array.from({ length: 7 }, (_, i) => [i + 1, { status: 'not measured', reason: 'Run has not reached this measurement' }])),
  limits: { budgetSampleMs: 21000, baselineSampleMs: 21000, cpuIntervalMs: 1000, windowWatchMs: 100, menuIdleSeconds: 5, menuWaitMs: 120000, menuTimerMs: 1200, latencyRuns: 20 },
  provenance: { requested: 'User Phase 0 brief, 2026-11-02; native authorization included', configuration: 'Private design plan §2 and D6 (read in place, not copied)',
    api: 'Local macOS SDK ScreenCaptureKit/SCStream.h and VideoToolbox/VTCompressionProperties.h',
    busyBaseline: 'Method choice: busy if one-minute load exceeds logical CPUs, WindowServer >3% of one core, or helper >1%; repeat exactly once. Thresholds are not an Apple guarantee.',
    sampleSchedule: 'Method choice: six evenly spaced PNG opportunities per lifecycle run; capture only the requested filter',
    outOfScope: 'User brief: Spaces, full screen, second display, Video menu controls, battery drain, powermetrics. Time-based reconfirmation cannot be tested in a day.' } };
const owned = new Set();
let monitor, latest, devPid, helperPid, wsPid, foregroundViolation, monitorError;
let monitorLines = [], fixtures = [], calculatorPid;
process.on('SIGINT', () => { monitorError = 'Harness interrupted with SIGINT'; });
process.on('SIGTERM', () => { monitorError = 'Harness interrupted with SIGTERM'; });
const appBinary = join(root, 'dist/Open Computer Use.app/Contents/MacOS/OpenComputerUse');
const processRows = () => run('ps', ['-axo', 'pid=,ppid=,args=']).split('\n').map(s => {
  const m = s.trim().match(/^(\d+)\s+(\d+)\s+(.*)$/); return m && { pid: +m[1], parent: +m[2], args: m[3] };
}).filter(Boolean);
const front = () => latest?.frontmost;
const check = () => { if (foregroundViolation) throw Error(foregroundViolation); if (monitorError) throw Error(monitorError); };
const avg = a => a.length ? a.reduce((a, b) => a + b, 0) / a.length : null;
const stats = a => { const s = [...a].sort((a, b) => a - b); return { count: s.length, medianMs: s.length ? (s[Math.floor((s.length - 1) / 2)] + s[Math.floor(s.length / 2)]) / 2 : null, p95Ms: s.length ? s[Math.ceil(s.length * .95) - 1] : null }; };
async function until(fn, label, timeout = 15000) {
  const end = Date.now() + timeout;
  while (Date.now() < end) { check(); try { const v = await fn(); if (v) return v; } catch (e) { if (e.code !== 'ENOENT' && !(e instanceof SyntaxError)) throw e; } await sleep(50); }
  throw Error(`Timed out: ${label}`);
}
async function save() {
  await writeFile(join(dir, 'results.json'), JSON.stringify(results, null, 2));
  const lines = ['# Phase 0 stream measurements', '', `Started: ${results.started}`, `Runtime: ${runtime}`, '',
    results.error ? `Stopped: ${results.error}` : 'See results.json for raw frame metadata, process samples, case boundaries and errors.', '',
    '## Answers', ...Object.entries(results.answers).flatMap(([n, a]) => ['', `### ${n}. ${a.title ?? ''}`, '', a.summary ?? `${a.status}: ${a.reason}`]), '',
    '## Cases', '', ...results.measurements.map(c => `- ${c.name}: ${c.error ?? c.skipped ?? (c.probe ? JSON.stringify(c.probe.streams.map(s => ({ windowID: s.windowID, counts: s.countsByStatus, firstFrameMs: s.firstFrameLatencyMs, stopErrors: s.stopErrors }))) : 'recorded')}`), '',
    '## Method and limits', '',
    'Foreground and system-window metadata: read-only CGWindowListCopyWindowInfo observer at 100 ms; fixture also records workspace activation notifications and state every 200 ms, polls commands every 20 ms. Window titles from other apps are not recorded. A brief window between samples may be missed. No input is sent.',
    'CPU: ps cumulative CPU time differences, 21 s or longer per idle baseline and stream row, sampled every second. 100% means one CPU core. RSS is resident memory, not footprint or allocated IOSurface memory; differences are reported, not treated as total GPU memory. System load is recorded at each sample. Busy baselines are repeated once using the recorded method threshold.',
    'Screenshots from stream: timing is inside the helper, request mach_absolute_time to arrival of the first complete/idle sample with a strictly later displayTime. Idle reuses the retained complete frame. One-off timing includes file IPC and JPEG writing; these are different endpoints, disclosed here. Twenty requests per load are retained, including unanswered requests.',
    'Indicator PNG limitation: taking a “before” image with a stream itself starts a stream. Window-list observations immediately before that request are the independent baseline. Indicator changes from other concurrent apps cannot be uniquely attributed without a controlled Mac. No Video menu interaction occurs.',
    'The display filter sourceRect is the union of the explicitly supplied windows, at one pixel per point, matching the screenshot composition region. Window filters use the target window size. Neither filter includes user app windows.',
    'Time-based Screen Recording reconfirmation cannot be tested in a day. Other Spaces, full screen, another display, Video menu controls, battery drain and powermetrics are not measured, as specified in the brief.', '',
    '## Provenance', '', ...Object.entries(results.provenance).map(([k, v]) => `- ${k}: ${v}`), '',
    '## Visual review', '', results.visualReview ?? 'Not yet inspected. Do not treat PNG existence as a visual conclusion.', ''];
  await writeFile(join(dir, 'report.md'), lines.join('\n'));
}
async function helper(action, payload = {}, timeoutMs = 3000) {
  check(); const response = await requestComputerUseHelper(commands, action, payload, { timeoutMs }); check();
  if (!response.success) throw Error(`${action}: ${response.error ?? JSON.stringify(response)}`);
  return JSON.parse(response.stdout);
}
async function command(f, name, extra = {}) {
  check(); const id = `${Date.now()}-${Math.random()}`;
  await writeFile(`${f.commands}.tmp`, JSON.stringify({ id, command: name, ...extra })); await rename(`${f.commands}.tmp`, f.commands);
  return until(async () => { const s = JSON.parse(await readFile(f.state, 'utf8')); if (s.last_command !== id) return false; if (s.command_error) throw Error(s.command_error); return s; }, `${name} acknowledged`);
}
async function fixture(index) {
  const app = join(dir, `StreamFixture-${index}.app`), executable = join(app, 'Contents/MacOS/StreamFixture');
  await mkdir(join(app, 'Contents/MacOS'), { recursive: true });
  execFileSync('xcrun', ['swiftc', 'tests/native-fixtures/StreamFixture.swift', '-o', executable]);
  await writeFile(join(app, 'Contents/Info.plist'), `<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleName</key><string>OCU Stream Fixture ${index}</string><key>CFBundleExecutable</key><string>StreamFixture</string><key>CFBundleIdentifier</key><string>com.andrewslabmd.opencomputeruse.streamfixture.${index}</string><key>CFBundlePackageType</key><string>APPL</string><key>LSUIElement</key><true/></dict></plist>`);
  const f = { state: join(dir, `fixture-${index}.json`), commands: join(dir, `commands-${index}.json`) };
  const before = front(); run('open', ['-g', '-n', app, '--args', f.state, f.commands]);
  const state = await until(async () => JSON.parse(await readFile(f.state, 'utf8')), 'fixture launch');
  f.pid = state.pid; f.window = state.window; f.initial = state; owned.add(f.pid); fixtures.push(f);
  await until(() => latest.windows.some(w => w.id === f.window && w.onScreen && w.bounds.Width > 0 && w.bounds.Height > 0), 'fixture window committed to Window Server');
  check(); if (front()?.pid === f.pid || state.foreground_changes.some(e => e.to === f.pid)) throw Error('Fixture came to front at launch');
  results.measurements.push({ name: `launch-fixture-${index}`, before, after: front(), state }); await save(); return f;
}
async function caseRun(name, fn) {
  check(); console.log(name);
  const row = { name, started: Date.now(), before: front(), windowSnapshotBefore: latest };
  results.measurements.push(row);
  try { await fn(row); } catch (e) { row.error = e.message; throw e; }
  finally {
    row.ended = Date.now(); row.after = front(); row.windowSnapshotAfter = latest;
    for (const f of fixtures) { try { const s = JSON.parse(await readFile(f.state, 'utf8')); (row.fixtureStates ??= []).push(s); if (s.foreground_changes.some(e => [devPid, ...fixtures.map(f => f.pid)].includes(e.to))) foregroundViolation = 'Fixture or OCU came to front (fixture activation log)'; } catch {} }
    await save();
  }
  check(); return row;
}
async function probe(row, f, options = {}, during) {
  const { samples = 6, ...parameters } = options;
  const request = { windowID: f.window, filter: 'window', includeChildWindows: false, fps: 15, durationMs: 4000,
    sampleDirectory: join(dir, 'frames', row.name), sampleCount: samples, ...parameters };
  row.request = request; row.requestSent = Date.now();
  const pending = helper('streamProbe', { streamProbe: request }, request.durationMs * 4 + 15000);
  // Attach immediately so a rejected request isn't unhandled during a transition.
  const settled = pending.then(value => ({ value }), error => ({ error }));
  if (during) await during(row);
  const result = await settled; if (result.error) throw result.error;
  row.probe = result.value; row.responseReceived = Date.now(); return row.probe;
}
async function idleForMenu(row) {
  const end = Date.now() + 120000;
  while ((latest?.idleSeconds ?? 0) < 5 && Date.now() < end) { check(); await sleep(250); }
  row.idleSeconds = latest?.idleSeconds;
  if (row.idleSeconds < 5) { row.skipped = 'No five-second HID idle interval in two minutes'; return false; } return true;
}
function cpuTime(s) { const parts = s.split(':').map(Number); return parts.reduce((a, n) => a * 60 + n, 0); }
function processSample() {
  const rows = run('ps', ['-p', `${helperPid},${wsPid}`, '-o', 'pid=,time=,rss=,pcpu=']).split('\n').map(s => s.trim().split(/\s+/));
  return { at: Date.now(), loadAverage: loadavg(), processes: rows.map(([pid, time, rss, pcpu]) => ({ pid: +pid, cpuSeconds: cpuTime(time), rssKB: +rss, psCPUPercent: +pcpu })) };
}
async function sampleProcesses(ms) {
  const samples = [processSample()], end = Date.now() + ms;
  while (Date.now() < end) { check(); await sleep(Math.min(1000, end - Date.now())); samples.push(processSample()); }
  const first = samples[0], last = samples.at(-1), seconds = (last.at - first.at) / 1000;
  const summarise = pid => { const a = first.processes.find(p => p.pid === pid), b = last.processes.find(p => p.pid === pid); return a && b ? { cpuPercent: 100 * (b.cpuSeconds - a.cpuSeconds) / seconds, rssMeanKB: avg(samples.map(s => s.processes.find(p => p.pid === pid)?.rssKB).filter(Number.isFinite)), rssPeakKB: Math.max(...samples.map(s => s.processes.find(p => p.pid === pid)?.rssKB).filter(Number.isFinite)) } : { unavailable: true }; };
  return { seconds, samples, helper: summarise(helperPid), windowServer: summarise(wsPid) };
}

// Standalone read-only observer, not an app binary and never a capture caller.
const observerSource = `import AppKit
import CoreGraphics
import Foundation
import Darwin
func emit() {
 let app = NSWorkspace.shared.frontmostApplication
 let windows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
 let ordered = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
 let output: [String: Any] = ["at": Date().timeIntervalSince1970 * 1000, "frontmost": ["pid": app?.processIdentifier ?? 0, "bundle": app?.bundleIdentifier ?? "", "name": app?.localizedName ?? ""], "idleSeconds": CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: UInt32.max)!), "windows": windows.map { w -> [String: Any] in ["id": w[kCGWindowNumber as String] ?? 0, "pid": w[kCGWindowOwnerPID as String] ?? 0, "owner": w[kCGWindowOwnerName as String] ?? "", "layer": w[kCGWindowLayer as String] ?? 0, "bounds": w[kCGWindowBounds as String] ?? [:], "onScreen": w[kCGWindowIsOnscreen as String] ?? false, "alpha": w[kCGWindowAlpha as String] ?? 0] }]
 var record = output
 record["onScreenWindowOrder"] = ordered.compactMap { $0[kCGWindowNumber as String] }
 print(String(data: try! JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]), encoding: .utf8)!); fflush(stdout)
}
emit()
Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in emit() }
RunLoop.main.run()
`;

try {
  const dev = await until(() => {
    const found = processRows().filter(p => p.args === appBinary);
    if (found.length > 1) throw Error('More than one running app from this worktree/dist');
    return found[0];
  }, 'worktree dev app launch');
  devPid = dev.pid;
  const helperProcess = await until(() => processRows().find(p => p.parent === devPid && p.args.includes('--command-directory ' + commands)), 'isolated dev helper launch');
  helperPid = helperProcess.pid;
  wsPid = processRows().find(p => /\/WindowServer(?:\s|$)/.test(p.args))?.pid;
  if (!wsPid) throw Error('WindowServer PID not found; CPU measurement cannot use a substitute');
  results.processes = { devPid, helperPid, wsPid, devExecutable: appBinary };
  // This is deliberately the first helper action. No grant-request action exists in this harness.
  results.permissions = await helper('permissionStatus');
  if (!results.permissions.find(p => p.name === 'Screen Recording')?.isGranted) {
    results.error = 'Screen Recording is not granted to the dev helper. Stopped without requesting permission.';
    process.exitCode = 1;
    for (const a of Object.values(results.answers)) a.reason = results.error;
  } else {
    await writeFile(join(dir, 'observer.swift'), observerSource);
    execFileSync('xcrun', ['swiftc', join(dir, 'observer.swift'), '-o', join(dir, 'observer')]);
    monitor = spawn(join(dir, 'observer'), [], { stdio: ['ignore', 'pipe', 'pipe'] });
    monitor.on('error', e => { monitorError = e.message; });
    monitor.on('exit', code => { if (!results.finished) monitorError = `Window observer exited ${code}`; });
    monitor.stderr.on('data', data => { monitorError = data.toString(); });
    createInterface({ input: monitor.stdout }).on('line', line => {
      try {
        latest = JSON.parse(line); monitorLines.push(latest);
        const forbidden = [devPid, ...owned].includes(latest.frontmost.pid);
        if (forbidden && !foregroundViolation) {
          foregroundViolation = `OCU or a launched test app came to front: ${latest.frontmost.pid}`;
          // Cancel only this process's in-flight file requests. Probe checks cancellation every 50 ms.
          void readdir(commands).then(async names => { for (const name of names.filter(n => /^request-.*\.json$/.test(n))) { const path = join(commands, name); try { if (JSON.parse(await readFile(path, 'utf8')).ownerProcessID === process.pid) await rm(path); } catch {} } });
        }
      } catch (e) { monitorError = e.message; }
    });
    await until(() => latest, 'window observer'); check();
    const f = await fixture(1);
    results.fixtureSize = f.initial.frame.slice(2); results.screen = f.initial.screen;
    const menuWindows = () => latest.windows.filter(w => w.owner === 'Control Center' && w.onScreen && w.bounds.Y <= 40 && w.bounds.Height <= 80);
    for (const phase of ['before', 'during']) {
      await caseRun(`indicator-menu-${phase}`, async row => {
        const windows = menuWindows(); row.controlCenterWindows = windows;
        if (!windows.length) { row.skipped = 'No on-screen Control Center menu-bar windows'; return; }
        // Both PNGs are explicitly requested streams. Independent before evidence is the observer list.
        await probe(row, { window: windows[0].id }, { filter: 'display', windowIDs: windows.map(w => w.id), durationMs: 1200, samples: 1 });
      });
      if (phase === 'before') {
        await caseRun('indicator-one-off', async row => {
          const path = join(runtime, 'observations', `indicator-${Date.now()}.jpg`); await mkdir(join(runtime, 'observations'), { recursive: true });
          row.capture = await helper('captureApplicationSurface', { preview: { kind: 'pid', value: String(f.pid), windowIDs: [f.window], path } }, 30000);
          row.captureFinished = Date.now(); await sleep(6000);
        });
        await caseRun('indicator-stream', async row => {
          await probe(row, f, { durationMs: 5000, samples: 2 }, async () => {
            await sleep(1500); row.duringSnapshot = latest;
            row.duringControlCenterWindows = menuWindows();
          });
          row.streamStopped = Date.now(); await sleep(10000);
        });
      }
    }
    const indicatorSamples = results.measurements.filter(c => c.name.startsWith('indicator-menu')).flatMap(c => c.probe?.streams.flatMap(s => s.sampleFrames) ?? []);
    results.answers[1] = { status: indicatorSamples.length ? 'partial' : 'not measured', title: 'Capture indicator', summary: indicatorSamples.length
      ? 'System-window observations and Control Center-only samples are retained. Taking a before PNG itself starts a stream. Menu-bar presence and persistence need visual comparison with the recorded case timestamps.'
      : 'Menu-bar indicator presence, persistence and requested PNGs are not measured: no eligible on-screen Control Center menu-bar window IDs were exposed. Before/during/after system-window observations remain in windows.jsonl; no other image was substituted.' };
    for (const filter of ['window', 'display']) {
      for (const state of ['covered', 'minimized', 'hidden', 'resized', 'hidden-from-capture', 'closed']) {
        await caseRun(`${filter}-${state}`, async row => {
          await command(f, 'animate');
          await probe(row, f, { filter, windowIDs: [f.window], durationMs: 4500 }, async () => {
            await sleep(1300); row.transitionAt = Date.now();
            if (state === 'minimized') await command(f, 'minimize');
            if (state === 'hidden') await command(f, 'hide');
            if (state === 'resized') await command(f, 'resize', { width: Math.floor(f.initial.frame[2] * .7), height: Math.floor(f.initial.frame[3] * .7) });
            if (state === 'hidden-from-capture') await command(f, 'sharingNone');
            if (state === 'closed') await command(f, 'close');
          });
        });
        if (state === 'minimized') await command(f, 'restore');
        if (state === 'hidden') await command(f, 'unhide');
        if (state === 'resized') await command(f, 'resize', { width: f.initial.frame[2], height: f.initial.frame[3] });
        if (state === 'hidden-from-capture') await command(f, 'sharingReadOnly');
        if (state === 'closed') {
          process.kill(f.pid, 'SIGTERM'); owned.delete(f.pid);
          const fresh = await fixture(fixtures.length + 1); Object.assign(f, fresh);
        }
      }
    }
    results.answers[3] = { status: 'measured', title: 'Window lifecycle, both filters', summary: 'Six lifecycle cases for each filter: covered behind existing user windows, then minimized, hidden, resized, sharingType.none, closed at the recorded transition time while streaming. Raw statuses, metadata, errors and up to six sample frames per case are retained. The covered case includes front-to-back window bounds for occlusion verification.' };
    for (const filter of ['window', 'display']) for (const includeChildWindows of [false, true]) for (const [kind, close] of [['child', 'closeChild'], ['popover', 'closePopover'], ['sheet', 'closeSheet'], ['context', null]]) {
      await caseRun(`${filter}-children-${includeChildWindows}-${kind}`, async row => {
        await command(f, 'solid');
        if (kind === 'context' && !await idleForMenu(row)) return;
        let state = await command(f, kind); await sleep(150);
        if (kind === 'context') state = JSON.parse(await readFile(f.state, 'utf8'));
        row.openState = state;
        await probe(row, f, { filter, includeChildWindows, windowIDs: state.window_ids, durationMs: kind === 'context' ? 1800 : 2500, samples: kind === 'context' ? 3 : 2 });
        if (close) await command(f, close);
      });
    }
    results.answers[4] = { status: 'measured', title: 'Child, popover, sheet and context menu', summary: 'Each surface was opened by the fixture, streamed with includeChildWindows false/true under the window filter and with the full fixture window list under the display filter. Context menus used the five-second HID idle gate and a 1.2 s event-tracking timer. Skips, if any, are explicit per case. Inspect corresponding PNGs for inclusion.' };
    const three = [f, await fixture(fixtures.length + 1), await fixture(fixtures.length + 1)];
    for (const load of ['still', 'animate']) for (const fps of [5, 15]) for (const encode of [false, true]) {
      for (let attempt = 0; attempt < 2; attempt++) {
        let busy;
        await caseRun(`budget-${load}-${fps}-${encode}-${attempt}`, async row => {
          for (const fixture of three) await command(fixture, 'still');
          await command(f, load); await sleep(500);
          row.baseline = await sampleProcesses(21000);
          busy = row.baseline.samples.some(s => s.loadAverage[0] > cpus().length) || row.baseline.windowServer.cpuPercent > 3 || row.baseline.helper.cpuPercent > 1;
          row.busyBaseline = busy;
          // No PNG writing in budget rows: its CPU cost is outside this measurement.
          await probe(row, f, { fps, encode, durationMs: 23000, samples: 0 }, async () => { await sleep(1000); row.running = await sampleProcesses(21000); });
          row.windowServerCPUChange = row.running.windowServer.cpuPercent - row.baseline.windowServer.cpuPercent;
          row.helperRSSChangeKB = row.running.helper.rssMeanKB - row.baseline.helper.rssMeanKB;
          row.encodedBitrate = row.probe.streams.reduce((n, s) => n + s.encoder.outputBytes, 0) * 8 / 23;
        });
        if (!busy) break;
      }
    }
    for (let attempt = 0; attempt < 2; attempt++) {
      let busy;
      await caseRun(`budget-three-animate-15-encode-${attempt}`, async row => {
      for (const f of three) await command(f, 'animate');
      row.baseline = await sampleProcesses(21000);
      busy = row.baseline.samples.some(s => s.loadAverage[0] > cpus().length) || row.baseline.windowServer.cpuPercent > 3 || row.baseline.helper.cpuPercent > 1;
      row.busyBaseline = busy;
      await probe(row, f, { fps: 15, encode: true, concurrentWindowIDs: three.slice(1).map(f => f.window), durationMs: 23000, samples: 0 }, async () => { await sleep(1000); row.running = await sampleProcesses(21000); });
      row.windowServerCPUChange = row.running.windowServer.cpuPercent - row.baseline.windowServer.cpuPercent;
      row.helperRSSChangeKB = row.running.helper.rssMeanKB - row.baseline.helper.rssMeanKB;
      row.encodedBitrate = row.probe.streams.reduce((n, s) => n + s.encoder.outputBytes, 0) * 8 / 23;
      });
      if (!busy) break;
    }
    for (const load of ['still', 'animate']) {
      await command(f, load);
      await caseRun(`latency-stream-${load}`, async row => {
        await probe(row, f, { durationMs: 12000, samples: 0, screenshotRequestTimesMs: Array.from({ length: 20 }, (_, i) => 1000 + i * 500) });
        row.summary = stats(row.probe.streams[0].screenshotTimings.map(s => s.latencyMs));
      });
      await caseRun(`latency-screenshot-${load}`, async row => {
        row.runs = []; await mkdir(join(runtime, 'observations'), { recursive: true });
        for (let i = 0; i < 20; i++) {
          const started = performance.now();
          const value = await helper('captureApplicationSurface', { preview: { kind: 'pid', value: String(f.pid), windowIDs: [f.window], path: join(runtime, 'observations', `latency-${load}-${i}.jpg`) } }, 30000);
          row.runs.push({ latencyMs: performance.now() - started, result: value });
        }
        row.summary = stats(row.runs.map(s => s.latencyMs));
      });
    }
    results.answers[6] = { status: 'measured', title: 'CPU, RSS, bitrate and latency', summary: `Fixture entire-window size ${results.fixtureSize.join('×')} points; display ${results.screen.join('×')}. Eight budget combinations, immediate idle baselines, one repeat for busy baselines, three simultaneous encoded streams, and 20 screenshot requests per mode/load are retained. CPU uses ≥21 s process-time deltas. RSS and encoded output bytes are recorded; no decoder is included. See budget and latency case rows.` };
    await caseRun('calculator-10s', async row => {
      let apps = processRows().filter(p => /\/Calculator\.app\/Contents\/MacOS\/Calculator$/.test(p.args));
      row.alreadyRunning = apps.length > 0;
      if (!apps.length) {
        run('open', ['-g', '-a', 'Calculator']);
        apps = await until(() => { const a = processRows().filter(p => /\/Calculator\.app\/Contents\/MacOS\/Calculator$/.test(p.args)); return a.length && a; }, 'Calculator launch');
        calculatorPid = apps[0].pid; owned.add(calculatorPid);
      }
      const pid = apps[0].pid;
      const w = await until(() => latest.windows.find(w => w.pid === pid && w.layer === 0 && w.onScreen), 'Calculator window');
      row.pid = pid; row.window = w;
      await probe(row, { window: w.id }, { durationMs: 10000, samples: 2 });
    });
    results.answers[7] = { status: 'measured', title: 'Calculator', summary: 'Calculator window streamed read-only for 10 s, with statuses and sample PNGs. Existing Calculator was left running; a newly launched instance is recorded and terminated by PID during cleanup.' };
  }
} catch (e) { results.error = e.stack; console.error(e); process.exitCode = 1; }
finally {
  results.finished = new Date().toISOString();
  if (monitor) monitor.kill('SIGTERM');
  await writeFile(join(dir, 'windows.jsonl'), monitorLines.map(s => JSON.stringify(s)).join('\n') + (monitorLines.length ? '\n' : ''));
  if (monitorLines.length) {
    const promptOwners = /UserNotificationCenter|tccd|universalAccessAuthWarn|SecurityAgent|CoreServicesUIAgent/i;
    results.privacyWindows = monitorLines.flatMap(s => s.windows.filter(w => w.onScreen && promptOwners.test(w.owner)).map(w => ({ at: s.at, ...w })));
    results.answers[2] = { status: 'measured', title: 'Privacy prompts', summary: `${results.privacyWindows.length} on-screen window observations owned by monitored prompt processes across ${monitorLines.length} window-list samples. Owners watched: ${promptOwners}. This does not prove absence of a sub-100 ms window or an unrecognized owner. Time-based Screen Recording reconfirmation cannot be tested in a day.` };
    const streams = results.measurements.flatMap(r => r.probe?.streams ?? []);
    results.answers[5] = { status: streams.length ? 'measured' : 'not measured', title: 'Grant attribution', summary: streams.length ? `Read-only permissionStatus reported the dev helper's existing Screen Recording grant; ${streams.length} streams ran under the dev app/helper identity. No permission-request actions were called. Prompt-owner observations are in answer 2. Privacy settings entries were not inspected because settings are out of scope.` : 'No successful stream results; see the stop reason.' };
  }
  results.foregroundViolation = foregroundViolation ?? null;
  results.cleanup = [];
  for (const pid of new Set([...owned, devPid].filter(Boolean))) {
    // Every PID is either returned by our just-launched fixture/Calculator, or
    // the exact worktree app whose cleanup the brief explicitly requests.
    try { process.kill(pid, 'SIGTERM'); results.cleanup.push({ pid, signal: 'SIGTERM' }); } catch (e) { results.cleanup.push({ pid, error: e.code }); }
  }
  await save(); console.log(`Results: ${dir}`);
}
