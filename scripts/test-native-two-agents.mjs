import assert from 'node:assert/strict';
import { execFileSync, spawn } from 'node:child_process';
import { mkdir, readFile, writeFile, rename } from 'node:fs/promises';
import { join } from 'node:path';
import { createInterface } from 'node:readline';
import { parse } from 'yaml';
import { Client } from '../packages/cli/client.mjs';
import { createNativeRun, expandNativeSnapshot, fixturePlist, launchNativeFixture } from './test-native-modes.mjs';

assert.ok(process.argv.includes('--interactive'), 'Two-agent native check requires --interactive authorization');
const ctx = await createNativeRun('two agents, two live streams, no cross-over', { outputGroup: 'stream-two' });
const { dir, runtime, results } = ctx;
const agents = ['A', 'B'].map((name, i) => ({ name, client: new Client(runtime, { name: `Agent ${name}` }),
  statePath: join(dir, `fixture-${name}.json`), commandPath: join(dir, `command-${name}.json`),
  palette: (i === 0 ? [[.9,.15,.05], [.95,.45,.05], [.8,.25,.15]] : [[.05,.25,.9], [.05,.7,.8], [.15,.35,.75]]),
  samples: [], calls: [], sources: {}, status: 'setup' }));
results.agents = agents.map(({ name, palette, samples, sources, calls }) => ({ name, palette, samples, sources, calls }));
results.method = { cyclesEach: 100, viewerFPS: 15, sharingSampleMs: 100, releaseDeadlineMs: 2000,
  toleranceRGB: 16, indicatorWindowMatch: results.method.indicatorWindowMatch,
  ownChoices: 'Disjoint three-colour warm/cool sRGB palettes listed per agent. Entire windows side by side, 16 pt gap, at most 640×480 pt each, within fixture-reported visible screen. Initial observe, subscription and first decoded frame establish readiness before the 100 simultaneous rounds. Each round dispatches both click→observe chains concurrently and waits for both; no delay or polling between click result and screenshot. Snapshots expand exact delivered deltas locally. Screenshot and every decoded viewer frame classified by center pixel, +/-16 per channel. Separate VideoToolbox sessions per agent; packet and decode counts must match. PNGs per agent at readiness, rounds 1/50/100, and B after release. B performs 10 extra cycles during/after A release. Viewer continuity threshold during simultaneous loop/release 500 ms (own choice, not promised fps); raw arrival and PTS gaps retained. CPU is helper cumulative ps time delta over the complete simultaneous loop, 100% = one core. Timer samples use fixture-PID 66×20 Window sharing marks; starts inferred from mark appearances and helper main-window target claims, no internal SCStream counter. Sub-100 ms restarts unverified. Service readiness 15 s / 50 ms polls, fixture readiness 10 s. Background/lock protection inherited from native-modes.' };
delete results.excludedSuites;
const messages = [];
let viewer, viewerStopping = false, harnessFailure;
const baseCheck = ctx.check;
ctx.check = () => { baseCheck(); if (harnessFailure) throw Error(harnessFailure); };
ctx.onSafety = () => { for (const a of agents) a.client.close(); viewerStopping = true; viewer?.kill('SIGTERM'); };
const originalSave = ctx.save;
ctx.save = async () => {
  summarize(); await originalSave();
  await writeFile(join(dir, 'viewer.jsonl'), messages.map(m => JSON.stringify(m)).join('\n') + '\n');
  await writeFile(join(dir, 'report.md'), [
    '# Two-agent native stream check', '', `Status: ${results.error ? 'stopped: ' + results.error : results.status ?? 'running'}`, '',
    ...results.agents.map(a => `- Agent ${a.name}: ${JSON.stringify({ ...a, samples: `${a.samples.length} rows in results.json`, calls: `${a.calls.length} rows in results.json` })}`), '',
    `Helper CPU: ${JSON.stringify(results.cpu ?? 'not measured')}`, '',
    `Release A while B works: ${JSON.stringify(results.release ?? 'not measured')}`, '',
    `Safety: session ${JSON.stringify(results.session)}, owned foreground samples ${ctx.watch.filter(s => s.owned).length}; user app switches ${results.userSwitches?.length ?? 0}.`, '',
    `Method and limitations: ${JSON.stringify(results.method)}`, '',
    `Visual review: ${results.visualReview ?? 'pending inspection of saved PNGs'}`, '',
    `Cleanup: ${JSON.stringify(results.cleanup)}; runtime remaining ${JSON.stringify(results.runtimeRemaining)}`, '',
    'Fixture-only development native check. This does not exercise the app’s PiP rendering and is not public release acceptance.', '',
  ].join('\n'));
};
const readState = async a => JSON.parse(await readFile(a.statePath, 'utf8'));
const flat = n => [n, ...(n.children ?? []).flatMap(flat)];
const button = a => a.observation?.snapshot?.surface?.windows.flatMap(w => flat(w.tree)).find(n => n.role === 'AXButton' && n.name === 'Change colour');
const matches = (rgb, palette) => palette.some(expected => rgb.every((v, i) => Math.abs(v - Math.round(expected[i] * 255)) <= 16));
function rowFor(a) { return results.agents.find(r => r.name === a.name); }
async function command(a, command, extra) {
  ctx.check(); const id = `${Date.now()}-${command}`;
  await writeFile(a.commandPath + '.tmp', JSON.stringify({ id, command, ...extra }));
  await rename(a.commandPath + '.tmp', a.commandPath);
  const state = await ctx.until(async () => { const s = await readState(a); return s.last_command === id && s; }, `${a.name} ${command}`);
  assert.equal(state.command_error, null); assert.equal(state.active, false);
  assert.ok(!state.foreground_changes.some(c => ctx.owned.has(c.to)), 'Owned process activated');
  return state;
}
async function monitor(phase) {
  await writeFile(ctx.monitorPath + '.tmp', JSON.stringify({ phase, fixtures: agents.map(a => ({ pid: a.pid, window: a.window })) }));
  await rename(ctx.monitorPath + '.tmp', ctx.monitorPath);
}
async function call(a, name, args) {
  ctx.check(); const measurement = { name, dispatchedAt: Date.now() / 1000 }; a.calls.push(measurement);
  try {
    const raw = await a.client.request('tools/call', { name, arguments: args });
    measurement.returnedAt = Date.now() / 1000;
    ctx.check(); assert.notEqual(raw.isError, true, JSON.stringify(raw));
    const observation = parse(raw.content.find(c => c.type === 'text').text);
    if (observation.snapshot) observation.snapshot = expandNativeSnapshot(a.observation?.snapshot, observation.snapshot);
    a.observation = observation;
    return { raw, observation };
  } catch (e) { measurement.error = e.message; harnessFailure ??= e.message; throw e; }
}
function cpuSample() {
  const [time, rss] = execFileSync('ps', ['-p', String(results.processes.helperPid), '-o', 'time=,rss='], { encoding: 'utf8' }).trim().split(/\s+/);
  return { at: performance.now(), cpuSeconds: time.split(':').map(Number).reduce((sum, n) => sum * 60 + n, 0), rssKB: +rss };
}
function send(message) { ctx.check(); viewer.stdin.write(JSON.stringify(message) + '\n'); }
async function snapshot(a, label) {
  send({ snapshot: label, agent: a.id });
  return ctx.until(() => messages.find(m => m.type === 'png' && m.agent === a.id && m.label === label), label);
}
function sampleRows(a, phases) {
  return ctx.watch.filter(s => s.source === 'timer' && phases.includes(s.monitor?.phase)).map(s => ({ at: s.at, phase: s.monitor.phase, ...s.fixtures?.find(f => f.pid === a.pid) }));
}
function presence(rows) {
  let previous = false, appearances = 0, disappearances = 0;
  for (const s of rows) {
    if (s.indicatorPresent && !previous) appearances++;
    if (!s.indicatorPresent && previous) disappearances++;
    previous = Boolean(s.indicatorPresent);
  }
  return { samples: rows.length, present: rows.filter(s => s.indicatorPresent).length,
    share: rows.length ? rows.filter(s => s.indicatorPresent).length / rows.length : null,
    appearances, disappearances, maxSimultaneousMarks: rows.length ? Math.max(...rows.map(s => s.indicators?.length ?? 0)) : 0, maxSampleGapMs: maxGap(rows.map(s => s.at)) };
}
function maxGap(times) { return times.length > 1 ? Math.max(...times.slice(1).map((t, i) => (t - times[i]) * 1000)) : null; }
function summarize() {
  for (const a of agents) {
    const row = rowFor(a), frames = messages.filter(m => m.agent === a.id && m.type === 'frame');
    const packets = messages.filter(m => m.agent === a.id && m.type === 'packet');
    const loopFrames = frames.filter(m => m.receivedAt >= results.loopStartedAt && m.receivedAt <= (results.loopFinishedAt ?? Infinity));
    const cursors = messages.filter(m => m.agent === a.id && m.type === 'cursor');
    const targets = messages.filter(m => m.agent === a.id && m.type === 'target');
    const active = sampleRows(a, a.name === 'A' ? ['baseline', 'claim', 'loop', 'after-loop'] : ['baseline', 'claim', 'loop', 'after-loop', 'release-A', 'B-continues']);
    const loop = sampleRows(a, ['loop']);
    let claimed = false, claims = 0;
    for (const s of active) {
      const next = s.helperTargets?.some(t => t.main_window_id === a.window) ?? false;
      if (next && !claimed) claims++;
      claimed = next;
    }
    Object.assign(row, { pid: a.pid, window: a.window, agent: a.id, status: a.status,
      screenshots: { loop: a.samples.filter(s => s.phase === 'loop').length,
        loopCorrect: a.samples.filter(s => s.phase === 'loop' && s.correct).length,
        crossOver: a.samples.filter(s => matches(s.centerRGB, agents.find(other => other !== a).palette)).length,
        totalCorrect: a.samples.filter(s => s.correct).length },
      viewer: { packets: packets.length, decoded: frames.length, crossOver: frames.filter(m => matches(m.centerRGB, agents.find(other => other !== a).palette)).length,
        outsideOwnPalette: frames.filter(m => !matches(m.centerRGB, a.palette)).length,
        maxArrivalGapMs: maxGap(loopFrames.map(m => m.receivedAt)), maxPTSGapMs: maxGap(loopFrames.map(m => m.pts)),
        allPhasesMaxArrivalGapMs: maxGap(frames.map(m => m.receivedAt)), allPhasesMaxPTSGapMs: maxGap(frames.map(m => m.pts)),
        targets: targets.length, wrongTarget: targets.filter(m => m.window_id !== a.window || m.pid !== a.pid).length,
        cursors: cursors.length, invalidCursors: cursors.filter(m => !cursorInside(a, m)).length },
      sharingMark: { loop: presence(loop), active: presence(active) },
      streams: { targetClaims: claims, indicatorAppearances: presence(active).appearances,
        inferredStarts: Math.max(claims, presence(active).appearances), unexpectedMainWindowIDs: [...new Set(active.flatMap(s => s.helperTargets ?? []).map(t => t.main_window_id).filter(id => id !== a.window))], exactInternalStartCount: 'unverified' } });
  }
}
function cursorInside(a, m) {
  if (!a.frame) return false;
  return [[m.x, m.y], ...(m.to_x !== undefined || m.to_y !== undefined ? [[m.to_x, m.to_y]] : [])]
    .every(([x,y]) => Number.isFinite(x) && Number.isFinite(y) && x >= 0 && y >= 0 && x < a.frame[2] && y < a.frame[3]);
}
async function cycle(a, iteration, phase) {
  try {
    const target = button(a); assert.ok(target?.id, 'Current Change colour button');
    const action = await call(a, 'use_action_batch', { actions: [{ kind: 'click', element: target.id }] });
    assert.equal(action.observation.status, 'completed', JSON.stringify(action.observation));
    const started = performance.now();
    const response = await call(a, 'use_observe', { app_target: `PID:${a.pid}`, include_screenshot: true });
    const latencyMs = performance.now() - started;
    const state = await readState(a), image = response.raw.content.find(c => c.type === 'image');
    assert.ok(image, JSON.stringify(response.raw));
    const path = join(dir, `${a.name}-${phase}-${iteration}.jpg`);
    await writeFile(path, Buffer.from(image.data, 'base64'));
    const keep = phase === 'loop' && [1,50,100].includes(iteration);
    const pixels = ctx.decode(path, keep ? path.replace('.jpg', '.png') : undefined);
    const expectedRGB = state.colour.map(v => Math.round(v * 255));
    const sample = { phase, iteration, pressCount: state.press_count, expectedRGB, ...pixels,
      capture_source: response.raw._meta?.capture_source, latencyMs, jpeg: path,
      correct: state.press_count === iteration && matches(state.colour.map(v => v * 255), a.palette)
        && pixels.centerRGB.every((v, i) => Math.abs(v - expectedRGB[i]) <= 16) };
    a.samples.push(sample); a.sources[sample.capture_source] = (a.sources[sample.capture_source] ?? 0) + 1;
    assert.equal(sample.correct, true, JSON.stringify(sample));
    assert.equal(sample.capture_source, 'live', 'Every measured screenshot must be live');
  } catch (e) { harnessFailure ??= e.message; throw e; }
}
async function together(tasks) {
  const settled = await Promise.allSettled(tasks);
  const failed = settled.find(r => r.status === 'rejected'); if (failed) throw failed.reason;
  ctx.check();
}
try {
  const app = join(dir, 'StreamFixture.app');
  await mkdir(join(app, 'Contents/MacOS'), { recursive: true });
  execFileSync('xcrun', ['swiftc', 'tests/native-fixtures/StreamFixture.swift', '-o', join(app, 'Contents/MacOS/StreamFixture')]);
  await writeFile(join(app, 'Contents/Info.plist'), fixturePlist('StreamFixture'));
  const decoder = join(dir, 'stream-client');
  execFileSync('xcrun', ['swiftc', '-O', '-D', 'STREAM_NATIVE_CLIENT', '-parse-as-library', 'scripts/native-stream-client.swift', '-o', decoder]);
  for (const a of agents) {
    const launched = await launchNativeFixture(app, [a.statePath, a.commandPath], a.statePath);
    ctx.owned.add(launched.pid);
    const initial = await readState(a); a.pid = initial.pid; a.window = initial.window;
    assert.equal(initial.active, false);
    const [x,y,w,h] = initial.visible_screen_frame;
    const width = Math.min(640, (w - 16) / 2), height = Math.min(480, h);
    a.frame = [x + (a.name === 'B' ? width + 16 : 0), y, width, height];
    a.fixture = await command(a, 'configure', { colours: a.palette, frame: a.frame });
    rowFor(a).fixture = a.fixture;
  }
  assert.notEqual(agents[0].pid, agents[1].pid);
  assert.ok(agents[0].frame[0] + agents[0].frame[2] <= agents[1].frame[0], 'Fixtures do not overlap');
  assert.equal((await ctx.helper('setCaptureMode', { mode: 'live' })).mode, 'live');
  await monitor('baseline');
  await ctx.until(() => ctx.watch.find(s => s.source === 'timer' && s.monitor?.phase === 'baseline'), 'baseline sample');
  for (const a of agents) assert.equal(sampleRows(a, ['baseline']).at(-1).indicatorPresent, false);
  await together(agents.map(a => a.client.connect(`Agent ${a.name}`)));
  await monitor('claim');
  await together(agents.map(a => call(a, 'use_observe', { app_target: `PID:${a.pid}` })));
  for (const a of agents) {
    assert.ok(button(a)?.id);
    const target = await ctx.until(async () => JSON.parse(await readFile(join(runtime, 'targets.json'), 'utf8')).find(t => t.pid === a.pid), `target ${a.name}`);
    a.id = target.client; assert.equal(target.name, `Agent ${a.name}`); assert.equal(target.main_window_id, a.window);
    await ctx.until(() => sampleRows(a, ['claim']).some(s => s.indicatorPresent), `${a.name} sharing mark`);
  }
  await mkdir(join(dir, 'frames'), { recursive: true });
  viewer = spawn(decoder, [runtime, join(dir, 'frames'), '--measure-every-frame'], { stdio: ['pipe', 'pipe', 'pipe'] });
  ctx.owned.add(viewer.pid);
  viewer.on('error', e => { harnessFailure ??= `Decoder: ${e.message}`; });
  viewer.on('exit', (code, signal) => { if (!viewerStopping) harnessFailure ??= `Decoder exited ${code}/${signal}`; });
  viewer.stderr.on('data', data => { (results.decoderStderr ??= []).push(String(data)); });
  createInterface({ input: viewer.stdout }).on('line', line => {
    try {
      const m = { ...JSON.parse(line), receivedAt: Date.now() / 1000 }; messages.push(m);
      if (['error','decode_error','client_error'].includes(m.type)) throw Error(JSON.stringify(m));
      const a = agents.find(a => a.id === m.agent);
      if (['frame','target','cursor','packet'].includes(m.type)) assert.ok(a, 'Message for unknown agent');
      if (m.type === 'frame') assert.ok(matches(m.centerRGB, a.palette), `Viewer colour cross-over/unknown: ${JSON.stringify(m)}`);
      if (m.type === 'target') { assert.equal(m.pid, a.pid); assert.equal(m.window_id, a.window); assert.equal(m.state, 'live'); }
      if (m.type === 'cursor') assert.ok(cursorInside(a, m), `Cursor outside fixture ${a.name}: ${JSON.stringify(m)}`);
      if (m.type === 'end' && !(m.agent === agents[0].id && results.release)) throw Error(`Unexpected stream end: ${JSON.stringify(m)}`);
    } catch (e) { harnessFailure ??= e.message; }
  });
  await ctx.until(() => messages.find(m => m.type === 'agents' && agents.every(a => m.agents.some(item => item.agent === a.id))), 'both agents listed');
  for (const a of agents) send({ type: 'subscribe', agent: a.id, max_fps: 15, codec: 'h264' });
  for (const a of agents) { await ctx.until(() => messages.find(m => m.type === 'frame' && m.agent === a.id), `${a.name} decoded readiness`); await snapshot(a, `${a.name}-ready`); a.status = 'running'; }
  await monitor('loop'); results.loopStartedAt = Date.now() / 1000; const cpuStart = cpuSample();
  for (let i = 1; i <= 100; i++) {
    await together(agents.map(a => cycle(a, i, 'loop')));
    if ([1,50,100].includes(i)) for (const a of agents) await snapshot(a, `${a.name}-${i}`);
    await ctx.save();
    if (i % 25 === 0) console.log(`Both agents: ${i}/100 correct live screenshots each`);
  }
  const cpuEnd = cpuSample(); results.loopFinishedAt = Date.now() / 1000;
  results.cpu = { start: cpuStart, end: cpuEnd, elapsedSeconds: (cpuEnd.at-cpuStart.at)/1000,
    helperCPUPercent: 100000 * (cpuEnd.cpuSeconds-cpuStart.cpuSeconds)/(cpuEnd.at-cpuStart.at), method: 'ps cumulative helper process CPU delta; 100% = one core; both viewer encoders subscribed for whole interval' };
  await monitor('after-loop'); summarize();
  for (const row of results.agents) {
    assert.equal(row.screenshots.loopCorrect, 100); assert.equal(row.sources.live, 100);
    assert.equal(row.sharingMark.loop.share, 1); assert.equal(row.sharingMark.active.appearances, 1);
    assert.equal(row.sharingMark.active.disappearances, 0); assert.equal(row.sharingMark.active.maxSimultaneousMarks, 1);
    assert.equal(row.streams.inferredStarts, 1); assert.deepEqual(row.streams.unexpectedMainWindowIDs, []);
    assert.ok(row.viewer.cursors > 0); assert.equal(row.viewer.invalidCursors, 0);
    assert.ok(row.viewer.decoded > 0); assert.equal(row.viewer.crossOver, 0); assert.equal(row.viewer.outsideOwnPalette, 0);
    assert.ok(row.viewer.maxArrivalGapMs <= 500, `Viewer arrival gap ${row.viewer.maxArrivalGapMs} ms`);
  }
  await monitor('release-A');
  results.release = { dispatchedAt: Date.now() / 1000, bFramesBefore: messages.filter(m => m.type === 'frame' && m.agent === agents[1].id).length };
  const releaseAt = performance.now();
  // Release and B's work overlap. The viewer stays subscribed: no mode change or unsubscribe hides a lifetime bug.
  await together([agents[0].client.request('release').then(() => { results.release.roundTripMs = performance.now() - releaseAt; }),
    (async () => { for (let i = 101; i <= 110; i++) { await cycle(agents[1], i, 'after-release'); await ctx.save(); } })(),
    (async () => {
      const gone = await ctx.until(() => {
        const sample = sampleRows(agents[0], ['release-A','B-continues']).find(s => s.at >= results.release.dispatchedAt && !s.indicatorPresent);
        assert.ok(sample || performance.now() - releaseAt <= 2000, 'A mark still present after 2 s');
        return sample;
      }, 'A sharing mark removed');
      results.release.aMarkGoneByMs = (gone.at - results.release.dispatchedAt) * 1000;
      assert.ok(results.release.aMarkGoneByMs <= 2000, 'A mark not removed within 2 s');
    })()]);
  await monitor('B-continues'); await snapshot(agents[1], 'B-after-release');
  results.release.finishedAt = Date.now() / 1000;
  const bFrames = messages.filter(m => m.agent === agents[1].id && m.type === 'frame');
  const bDuring = bFrames.filter(m => m.receivedAt >= results.release.dispatchedAt && m.receivedAt <= results.release.finishedAt);
  results.release.bFramesDuring = bDuring.length;
  results.release.bMaxArrivalGapMs = maxGap([results.release.dispatchedAt, ...bDuring.map(m => m.receivedAt), results.release.finishedAt]);
  results.release.bMark = presence(sampleRows(agents[1], ['release-A','B-continues']));
  results.release.aEnd = messages.find(m => m.type === 'end' && m.agent === agents[0].id);
  assert.equal(results.release.aEnd?.reason, 'released');
  assert.ok(results.release.bFramesDuring > 0); assert.ok(results.release.bMaxArrivalGapMs <= 500);
  assert.equal(results.release.bMark.share, 1);
  assert.ok(sampleRows(agents[0], ['release-A','B-continues']).filter(s => s.at > results.release.dispatchedAt + 2).every(s => !s.indicatorPresent), 'A mark reappeared');
  // Await each packet's callback before comparing counts; no extra input or task retry.
  for (const a of agents) {
    await ctx.until(() => messages.filter(m => m.type === 'packet' && m.agent === a.id).length === messages.filter(m => m.type === 'frame' && m.agent === a.id).length, `${a.name} decode drain`);
    const final = await readState(a); rowFor(a).finalFixture = final;
    assert.equal(final.active, false); assert.ok(!final.foreground_changes.some(c => ctx.owned.has(c.to)));
    a.status = 'passed';
  }
  ctx.check(); results.status = 'passed; visual review pending';
} catch (e) {
  results.error = e.stack; results.status = 'failed'; process.exitCode = 1; console.error(e.stack);
} finally {
  for (const a of agents) a.client.close();
  viewerStopping = true;
  if (viewer) {
    if (viewer.exitCode === null && viewer.signalCode === null) {
      const exited = new Promise(resolve => viewer.once('close', resolve));
      viewer.stdin.end(); viewer.kill('SIGTERM'); await exited;
    }
  }
  await ctx.cleanup();
}
