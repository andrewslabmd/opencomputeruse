import { spawnSync } from 'node:child_process';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { resolve, join } from 'node:path';
import assert from 'node:assert/strict';
import { parse } from 'yaml';
import { fixturePlist, launchNativeFixture } from './test-native-modes.mjs';
import { Client } from '../packages/cli/client.mjs';
import { assertFixtureFocus, waitForFixtureState } from './live-support/fixture-focus.mjs';
if (!process.argv.includes('--interactive')) throw new Error('Native UI test requires explicit --interactive authorization');
// This legacy fixture explicitly activates itself and the previous app. Refuse
// before launch under the isolated, strictly background-only Phase 2 run.
if (process.env.OCU_RUNTIME_DIR && /NSApp\.activate\(|previousApplication\?\.activate\(/.test(await readFile('tests/native-fixtures/ComputerUseFixture.swift', 'utf8'))) {
  console.error('Blocked: ComputerUseFixture.swift explicitly activates itself and the previous app; fixture changes are outside this brief. No app launched.');
  process.exit(78);
}
const app = resolve(`work/native-basic-${Date.now()}/ComputerUseFixture.app`);
await mkdir(join(app, 'Contents/MacOS'), { recursive: true });
await writeFile(join(app, 'Contents/Info.plist'), fixturePlist('ComputerUseFixture'));
const build = spawnSync('xcrun', ['swiftc', '-parse-as-library', 'tests/native-fixtures/ComputerUseFixture.swift', '-o', join(app, 'Contents/MacOS/ComputerUseFixture')], { stdio: 'inherit' });
if (build.status) process.exit(build.status);
const resultPath = resolve(`work/native-${Date.now()}.json`);
const fixture = await launchNativeFixture(app, [resultPath], resultPath);
const client = new Client();
try {
  await client.connect('Native acceptance fixture');
  await waitForFixtureState(resultPath, s => s.ready && !s.appActive); // fixture yields after initializing AX
  const observed = await client.request('tools/call', { name: 'use_observe', arguments: { app_target: `PID:${fixture.pid}`, include_screenshot: true } });
  assert.notEqual(observed.isError, true, JSON.stringify(observed));
  const state = parse(observed.content.find(c => c.type === 'text').text).snapshot;
  const image = observed.content.find(c => c.type === 'image');
  assert.ok(image, 'Native screenshot was not returned');
  await writeFile('work/native-fixture.jpg', Buffer.from(image.data, 'base64'));
  const nodes = [];
  function walk(node) { nodes.push(node); for (const child of node.children || []) walk(child); }
  for (const window of state.surface.windows) walk(window.tree);
  function point(name) { const node = nodes.find(n => n.name === name); assert.ok(node?.frame, `Missing ${name}`); return { x: node.frame[0] + node.frame[2] / 2, y: node.frame[1] + node.frame[3] / 2 }; }
  const actions = [
    { kind: 'click', at: point('Begin Test') },
    { kind: 'type', at: point('Fixture Input'), text: 'Standalone native acceptance', replace: true },
    { kind: 'click', at: point('Panel Action') },
    { kind: 'click', at: point('Commit') },
  ];
  const result = await client.request('tools/call', { name: 'use_action_batch', arguments: { actions } });
  const audit = parse(result.content.find(c => c.type === 'text').text);
  assert.equal(audit.status, 'completed', JSON.stringify(audit.actions));
  const native = await waitForFixtureState(resultPath, s => s.committed);
  assert.equal(native.text, 'Standalone native acceptance');
  assert.equal(native.panelActionPerformed, true);
  assertFixtureFocus(native, { active: true, pid: fixture.pid });
  const pending = client.request('tools/call', { name: 'use_action_batch', arguments: { actions: [
    { kind: 'wait', milliseconds: 10000 },
    { kind: 'type', at: point('Fixture Input'), text: 'must not execute', replace: true },
  ] } });
  const cancelled = assert.rejects(pending, { code: 'cancelled' });
  await new Promise(r => setTimeout(r, 200));
  await client.request('pause'); await cancelled;
  const stopped = await waitForFixtureState(resultPath, s => !s.appActive);
  assertFixtureFocus(stopped, { active: false, pid: fixture.pid });
  await client.request('resume');
  const afterStop = await client.request('tools/call', { name: 'use_observe', arguments: { app_target: `PID:${fixture.pid}` } });
  const afterState = parse(afterStop.content.find(c => c.type === 'text').text);
  assert.ok(JSON.stringify(afterState).includes('Standalone native acceptance'));
  assert.ok(!JSON.stringify(afterState).includes('must not execute'));
  // Start another lease so release, independently of Stop, must restore it.
  const recommit = await client.request('tools/call', { name: 'use_action_batch', arguments: { actions: [
    { kind: 'type', at: point('Fixture Input'), text: 'Standalone native acceptance', replace: true },
    { kind: 'click', at: point('Commit') },
  ] } });
  assert.notEqual(recommit.isError, true, JSON.stringify(recommit));
  assert.equal(parse(recommit.content.find(c => c.type === 'text').text).status, 'completed');
  const leased = await waitForFixtureState(resultPath, s => s.appActive);
  assertFixtureFocus(leased, { active: true, pid: fixture.pid });
  await client.request('release');
  const released = await waitForFixtureState(resultPath, s => !s.appActive);
  assertFixtureFocus(released, { active: false, pid: fixture.pid });
  const evidence = { passed: true, native, stopped, leased, released, actionCount: audit.actions.length, screenshot: true, stopPreventsQueuedTyping: true };
  // As in the click fixture, report physical pointer movement; it cannot
  // distinguish concurrent human movement from input sent by the product.
  await writeFile('work/native-acceptance.json', JSON.stringify(evidence, null, 2));
  console.log(JSON.stringify(evidence, null, 2));
} finally { await client.request('release').catch(() => {}); client.close(); fixture.kill('SIGTERM'); }
