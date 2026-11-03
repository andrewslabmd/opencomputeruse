import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdir, readFile, writeFile, rename } from 'node:fs/promises';
import { join } from 'node:path';
import { parse } from 'yaml';
import { Client } from '../packages/cli/client.mjs';
import { createNativeRun, fixturePlist, launchNativeFixture, sleep } from './test-native-modes.mjs';

if (!process.argv.includes('--interactive')) throw Error('Native live check requires --interactive authorization');
const ctx = await createNativeRun('live view versus screenshots');
const { results, dir, runtime } = ctx;
const agent = new Client(runtime);
ctx.onSafety = () => agent.close();
let fixture, statePath, commandPath;
const readState = async () => JSON.parse(await readFile(statePath, 'utf8'));
const flat = n => [n, ...(n.children ?? []).flatMap(flat)];
const button = observation => observation.snapshot.surface.windows.flatMap(w => flat(w.tree)).find(n => n.role === 'AXButton' && n.name === 'Change colour');
async function call(name, args) {
  ctx.check();
  const raw = await agent.request('tools/call', { name, arguments: args });
  ctx.check(); assert.notEqual(raw.isError, true, JSON.stringify(raw));
  return { raw, observation: parse(raw.content.find(c => c.type === 'text').text) };
}
async function command(command, extra = {}) {
  const id = `${Date.now()}-${command}`;
  await writeFile(commandPath + '.tmp', JSON.stringify({ id, command, ...extra }));
  await rename(commandPath + '.tmp', commandPath);
  const state = await ctx.until(async () => { const s = await readState(); return s.last_command === id && s; }, command);
  assert.equal(state.command_error, null); assert.equal(state.active, false);
  assert.ok(!state.foreground_changes.some(c => ctx.owned.has(c.to)), 'Owned process came forward');
  return state;
}
const percentile = (sorted, p) => sorted[Math.ceil(sorted.length * p) - 1];
function latency(samples) {
  const sorted = samples.map(s => s.latencyMs).sort((a, b) => a-b), half = sorted.length / 2;
  return { count: sorted.length, medianMs: (sorted[Math.floor((sorted.length-1)/2)] + sorted[Math.floor(half)]) / 2, p95Ms: percentile(sorted, .95) };
}
async function monitor(row, phase) {
  await writeFile(ctx.monitorPath + '.tmp', JSON.stringify({ pid: fixture.pid, window: fixture.window, mode: row.mode, phase }));
  await rename(ctx.monitorPath + '.tmp', ctx.monitorPath);
}
function presenceSummary(rows) {
  let previous = false, appearances = 0, disappearances = 0;
  for (const sample of rows) {
    if (sample.indicatorPresent && !previous) appearances++;
    if (!sample.indicatorPresent && previous) disappearances++;
    previous = sample.indicatorPresent;
  }
  const count = rows.filter(s => s.indicatorPresent).length;
  const gaps = rows.slice(1).map((s, i) => 1000 * (s.at - rows[i].at));
  return { samples: rows.length, presentSamples: count, presentShare: rows.length ? count / rows.length : null,
    appearances, disappearances, lastPresent: rows.at(-1)?.indicatorPresent,
    maxSampleGapMs: gaps.length ? Math.max(...gaps) : null };
}
function summarize(row) {
  const rows = ctx.watch.filter(s => s.source === 'timer' && s.monitor?.mode === row.mode);
  const active = rows.filter(s => s.monitor.phase !== 'released');
  const loop = rows.filter(s => s.monitor.phase === 'loop');
  // Start loop transitions from the immediately preceding sample, because a
  // stream established before iteration 1 is not a new appearance in the loop.
  const loopStart = rows.findIndex(s => s.monitor.phase === 'loop');
  const preceding = loopStart > 0 ? rows[loopStart - 1] : undefined;
  row.indicator = { loop: presenceSummary(loop), activeSession: presenceSummary(active), throughRelease: presenceSummary(rows) };
  if (preceding?.indicatorPresent && loop.length) {
    if (loop[0].indicatorPresent) row.indicator.loop.appearances--;
    else row.indicator.loop.disappearances++;
  }
  let previous = [], targetClaims = 0;
  const changes = [];
  for (const sample of rows) {
    if (!Array.isArray(sample.helperTargets)) continue;
    const ids = [...new Set(sample.helperTargets.map(t => t.main_window_id))].sort((a,b) => a-b);
    if (JSON.stringify(previous) !== JSON.stringify(ids)) {
      changes.push({ at: sample.at, phase: sample.monitor.phase, from: previous, to: ids });
      if (ids.includes(fixture.window) && !previous.includes(fixture.window)) targetClaims++;
      previous = ids;
    }
  }
  row.helperStreams = { inferredStarts: row.mode === 'live' ? Math.max(targetClaims, row.indicator.activeSession.appearances) : 0,
    fixtureTargetClaims: targetClaims, mainWindowChanges: changes, indicatorAppearances: row.indicator.activeSession.appearances,
    unexpectedMainWindowIDs: [...new Set(rows.flatMap(s => (s.helperTargets ?? []).map(t => t.main_window_id)).filter(id => id !== fixture.window))],
    method: '100 ms samples of helper-consumed targets.json plus fixture indicator appearances; inferred start count, not an internal SCStream start counter. Screenshots mode disables agent streams. Sub-100 ms restarts cannot be excluded.' };
}
async function oneOff(label) {
  const path = join(runtime, 'observations', `${label}.jpg`);
  const capture = await ctx.helper('captureApplicationSurface', { preview: { kind: 'pid', value: String(fixture.pid), windowIDs: [fixture.window], path } });
  const responseAt = performance.now();
  assert.equal(capture.capture_source, 'screenshot');
  const saved = join(dir, `${label}.jpg`); await writeFile(saved, await readFile(path));
  return { capture_source: capture.capture_source, responseAt, path: saved, pixels: ctx.decode(saved, join(dir, `${label}.png`)) };
}
try {
  const app = join(dir, 'StreamFixture.app');
  await mkdir(join(app, 'Contents/MacOS'), { recursive: true });
  execFileSync('xcrun', ['swiftc', 'tests/native-fixtures/StreamFixture.swift', '-o', join(app, 'Contents/MacOS/StreamFixture')]);
  await writeFile(join(app, 'Contents/Info.plist'), fixturePlist('StreamFixture'));
  statePath = join(dir, 'fixture.json'); commandPath = join(dir, 'command.json');
  const launched = await launchNativeFixture(app, [statePath, commandPath], statePath);
  ctx.owned.add(launched.pid); fixture = await readState();
  results.fixture = fixture;
  assert.equal(fixture.active, false);
  await agent.connect('Phase 2 native colour check');
  results.modes = ['live', 'screenshots'].map(mode => ({ mode, status: 'not run', passCount: 0, samples: [], sources: {} }));
  for (const row of results.modes) {
    const { mode } = row; row.status = 'running';
    assert.equal((await ctx.helper('setCaptureMode', { mode })).mode, mode);
    // The command file only prepares the solid background; all colour changes
    // measured below come from the AX-visible button via OCU action batches.
    await command('solid');
    await monitor(row, 'before-observe');
    const baseline = await ctx.until(() => ctx.watch.find(s => s.source === 'timer' && s.monitor?.mode === mode && s.monitor.phase === 'before-observe'), 'pre-claim indicator baseline');
    assert.equal(baseline.indicatorPresent, false, 'No indicator before the agent claims the fixture');
    assert.ok(baseline.fixtureWindows.some(w => w.id === fixture.window && w.title === 'OCU Stream Fixture'), 'Fixture window title must be readable by the sampler');
    await monitor(row, 'claim');
    let { observation } = await call('use_observe', { app_target: `PID:${fixture.pid}` });
    assert.ok(button(observation)?.id, 'AX-visible Change colour button');
    const initialCount = (await readState()).press_count;
    if (mode === 'live') await ctx.until(() => ctx.watch.find(s => s.source === 'timer' && s.monitor?.mode === mode && s.monitor.phase === 'claim' && s.indicatorPresent && s.helperTargets?.some(t => t.main_window_id === fixture.window)), 'live stream initial indicator and main-window target');
    row.loopStartedAt = Date.now() / 1000;
    await monitor(row, 'loop');
    for (let i = 1; i <= 100; i++) {
      const target = button(observation); assert.ok(target?.id, 'Current observed button');
      const action = await call('use_action_batch', { actions: [{ kind: 'click', element: target.id }] });
      assert.equal(action.observation.status, 'completed', JSON.stringify(action.observation));
      // No sleeps, command-file polling or additional tool calls between the
      // click result and the screenshot observation.
      const start = performance.now();
      const response = await call('use_observe', { app_target: `PID:${fixture.pid}`, include_screenshot: true });
      const latencyMs = performance.now() - start;
      observation = response.observation;
      const state = await readState(), image = response.raw.content.find(c => c.type === 'image');
      assert.ok(image, JSON.stringify(response.raw));
      const path = join(dir, `${mode}-${i}.jpg`);
      await writeFile(path, Buffer.from(image.data, 'base64'));
      const sampleImage = [1, 50, 100].includes(i);
      const pixels = ctx.decode(path, sampleImage ? join(dir, `${mode}-${i}.png`) : undefined);
      const expected = state.colour.map(v => Math.round(v * 255));
      const sample = { iteration: i, pressCount: state.press_count, expectedRGB: expected, ...pixels,
        capture_source: response.raw._meta?.capture_source, latencyMs,
        correct: state.press_count === initialCount + i && pixels.centerRGB.every((v, channel) => Math.abs(v - expected[channel]) <= 16),
        ...(sampleImage ? { jpeg: path, decodedPNG: join(dir, `${mode}-${i}.png`) } : {}) };
      row.samples.push(sample);
      row.latency = latency(row.samples);
      assert.ok(['live', 'screenshot'].includes(sample.capture_source), 'capture_source metadata missing');
      row.sources[sample.capture_source] = (row.sources[sample.capture_source] || 0) + 1;
      if (sample.correct) row.passCount++;
      // Retain every measurement before asserting; no retry on a stale frame.
      summarize(row); await ctx.save();
      assert.equal(sample.correct, true, JSON.stringify(sample));
      if (mode === 'screenshots') assert.equal(sample.capture_source, 'screenshot');
      if (i % 25 === 0) console.log(`${mode}: ${row.passCount}/${i} correct`);
    }
    row.loopFinishedAt = Date.now() / 1000;
    await monitor(row, 'after-loop');
    summarize(row);
    row.latency = latency(row.samples);
    assert.equal(row.passCount, 100);
    if (mode === 'live') {
      assert.ok(row.sources.live > 0, 'Live mode never served a live frame');
      assert.equal(row.indicator.loop.presentShare, 1, 'Live indicator must remain present throughout the loop');
      assert.equal(row.indicator.activeSession.appearances, 1, 'One live indicator appearance per agent claim');
      assert.equal(row.indicator.activeSession.disappearances, 0, 'Live indicator must not disappear before release');
      assert.equal(row.helperStreams.inferredStarts, 1, 'One inferred live stream start');
      assert.deepEqual(row.helperStreams.unexpectedMainWindowIDs, [], 'Helper target must stay on the fixture standard window');
    }
    // Use one-off captures for the indicator check so the measurement itself
    // does not start an agent stream. Switching mode leaves the OS pill's fade
    // observable; live screenshots above provide the required purple baseline.
    row.pillBaseline = row.samples.at(-1);
    if (mode === 'live') assert.ok(row.pillBaseline.purplePixels > 0, 'Purple baseline missing; disappearance cannot be proved');
    await monitor(row, 'released');
    const releaseAt = performance.now();
    row.releaseDispatchedAt = Date.now() / 1000;
    await agent.request('release'); ctx.check();
    row.releaseRoundTripMs = performance.now() - releaseAt;
    assert.equal((await ctx.helper('setCaptureMode', { mode: 'screenshots' })).mode, 'screenshots');
    row.pillChecks = [];
    // Schedule from release dispatch, every 250 ms; if capture processing
    // misses a slot, record that fact and fail instead of weakening cadence.
    for (let tick = 1; tick <= 8; tick++) {
      const due = releaseAt + tick * 250;
      await sleep(Math.max(0, due - performance.now())); ctx.check();
      const requestAt = performance.now();
      assert.ok(requestAt < due + 250, 'One-off capture missed an entire 250 ms polling slot');
      const capture = await oneOff(`${mode}-release-${tick}`);
      const check = { tick, scheduledMs: tick * 250, requestMs: requestAt-releaseAt,
        responseMs: capture.responseAt-releaseAt, ...capture };
      delete check.responseAt;
      check.absent = check.pixels.purplePixels === 0 && check.pixels.greyPixels > 0;
      row.pillChecks.push(check); summarize(row); await ctx.save();
      if (check.absent) { row.pillGoneByMs = check.responseMs; break; }
    }
    assert.ok(row.pillGoneByMs <= 2000, `Purple pill not proven gone within 2 s: ${row.pillGoneByMs ?? 'still present'}`);
    summarize(row);
    row.status = 'passed';
    console.log(`${mode}: ${row.passCount}/100; sources ${JSON.stringify(row.sources)}; latency ${JSON.stringify(row.latency)}; pill absent by ${row.pillGoneByMs.toFixed(1)} ms`);
  }
  results.finalFixture = await readState();
  assert.ok(!results.finalFixture.foreground_changes.some(c => ctx.owned.has(c.to)), 'Owned process activated');
  results.status = 'passed; sample visual review pending';
} catch (e) {
  results.error = e.stack;
  const row = results.modes.find(row => row.status === 'running');
  if (row) { summarize(row); row.status = 'failed'; row.error = e.message; }
  process.exitCode = 1; console.error(e.message);
}
finally {
  // Disconnect withdraws the target without more GUI input after a safety stop.
  agent.close(); await ctx.cleanup();
}
