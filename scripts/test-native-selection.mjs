import assert from 'node:assert/strict';
import { spawn, execFileSync } from 'node:child_process';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { join, resolve, basename } from 'node:path';
import { parse } from 'yaml';
import { Client } from '../packages/cli/client.mjs';

if (!process.argv.includes('--interactive')) throw new Error('Live native selection tests require explicit --interactive authorization');
const base = resolve(`work/native-selection-${Date.now()}`);
await mkdir(base, { recursive: true });
const binary = join(base, 'SelectionFixture');
execFileSync('xcrun', ['swiftc', '-parse-as-library', 'tests/native-fixtures/SelectionFixture.swift', '-o', binary]);
const statePath = join(base, 'fixture-state.json');
const client = new Client();
const records = [];
let fixture;
let finderWindowID;
const finderPath = join(base, `ocu-selection-items-${Date.now()}`);
const title = basename(finderPath);
const sleep = ms => new Promise(r => setTimeout(r, ms));
const decode = r => {
  assert.notEqual(r.isError, true, JSON.stringify(r));
  return parse(r.content.find(v => v.type === 'text').text);
};
const flat = n => [n, ...(n.children ?? []).flatMap(flat)];
const point = n => ({ x: n.frame[0] + n.frame[2] / 2, y: n.frame[1] + n.frame[3] / 2 });
const osa = source => JSON.parse(execFileSync('/usr/bin/osascript', ['-l', 'JavaScript', '-e', source], { encoding: 'utf8' }));
async function observe(app, windowTitle) {
  return decode(await client.request('tools/call', { name: 'use_observe', arguments: { app_target: app, window_title: windowTitle } })).snapshot;
}
async function act(action) {
  return decode(await client.request('tools/call', { name: 'use_action_batch', arguments: { actions: [action] } }));
}
try {
  await client.connect('Native selection contract acceptance');
  const host = await client.request('status');
  assert.ok(!host.busy && !host.owner && !host.paused, 'Host must be idle and ready');
  fixture = spawn(binary, [statePath], { stdio: 'ignore' });
  // Startup readiness only. No limit on an agent task or native workflow.
  const readyBy = Date.now() + 10000;
  while (true) {
    try { await readFile(statePath); break; } catch {
      assert.ok(Date.now() < readyBy && fixture.exitCode === null, 'Fixture did not start');
      await sleep(50);
    }
  }
  const specs = [
    ['table label', 'Table Alpha', 'table_rows', [0]],
    ['table image', 'Table Beta icon', 'table_rows', [1]],
    ['outline label', 'Outline Alpha', 'outline_rows', [1]],
    ['outline image', 'Outline Beta icon', 'outline_rows', [2]],
    ['collection label', 'Card 0-0', 'collection_items', [[0, 0]]],
    ['collection image', 'Card 0-1', 'collection_items', [[0, 1]]],
    ['second section label', 'Card 1-0', 'collection_items', [[1, 0]]],
    ['tab', 'Second tab', 'tab', 1],
    ['button', 'Fixture press', 'presses', 1],
    ['editor', 'Fixture editor', 'text', 'Verified fixture edit'],
  ];
  for (const [test, name, property, expected] of specs) {
    const snapshot = await observe(`PID:${fixture.pid}`, 'Selection contract fixture');
    const nodes = snapshot.surface.windows.flatMap(w => flat(w.tree));
    let target = nodes.find(n => n.name === name);
    assert.ok(target?.frame, `Missing ${name}`);
    if (test === 'collection image') {
      const item = nodes.find(n => n.children?.some(c => c.id === target.id));
      target = item?.children.find(n => n.role === 'AXImage');
      assert.ok(target?.frame, 'Missing picture inside the identified collection item');
    }
    const action = property === 'text'
      ? { kind: 'type', at: point(target), text: expected, replace: true }
      : { kind: 'click', at: point(target) };
    const result = await act(action);
    await sleep(80);
    const actual = JSON.parse(await readFile(statePath, 'utf8'));
    records.push({ test, actions: result.actions, actual });
    assert.equal(result.actions[0].status, 'completed', JSON.stringify(result.actions));
    // These are actual NSTableView/NSOutlineView/NSCollectionView selections,
    // tab state, button target invocations and NSTextField contents.
    assert.deepEqual(actual[property], expected);
    console.log(`${test}: passed`);
  }
  await client.request('release');
  await sleep(80);
  const released = JSON.parse(await readFile(statePath, 'utf8'));
  assert.equal(released.active, false);
  records.push({ test: 'fixture release', actual: released });

  await mkdir(finderPath);
  for (const name of ['alpha.txt', 'beta.txt', 'gamma.txt']) await writeFile(join(finderPath, name), `${name}: preserved content\n`);
  finderWindowID = Number(execFileSync('/usr/bin/osascript', ['-e', `tell application "Finder"
set trialWindow to make new Finder window
set target of trialWindow to (POSIX file ${JSON.stringify(finderPath)} as alias)
return id of trialWindow
end tell`], { encoding: 'utf8' }).trim());
  for (const view of ['icon view', 'list view', 'column view']) {
    // Test setup changes only this owned window's presentation.
    execFileSync('/usr/bin/osascript', ['-e', `tell application "Finder" to set current view of Finder window id ${finderWindowID} to ${view}`]);
    await sleep(400);
    for (const name of ['alpha.txt', 'beta.txt', 'gamma.txt']) {
      const snapshot = await observe('Finder', title);
      const window = snapshot.surface.windows.find(w => w.window_id === finderWindowID);
      assert.ok(window, 'Owned Finder window missing');
      const candidates = flat(window.tree).filter(n => n.frame && [n.name, n.value, n.identifier].includes(name));
      const target = candidates.find(n => n.role === 'AXImage') ?? candidates.find(n => n.role === 'AXStaticText') ?? candidates[0];
      assert.ok(target?.frame, `Missing ${name} in ${view}`);
      const result = await act({ kind: 'click', at: point(target) });
      const selected = osa('JSON.stringify(Application("Finder").selection().map(f => ({name:f.name(),url:f.url()})))');
      records.push({ test: `Finder ${view}: ${name}`, actions: result.actions, selected });
      assert.equal(result.actions[0].status, 'completed', JSON.stringify(result.actions));
      assert.deepEqual(selected.map(f => f.name), [name]);
      assert.equal(selected[0].url, new URL(`file://${join(finderPath, name)}`).href);
      assert.equal(await readFile(join(finderPath, name), 'utf8'), `${name}: preserved content\n`);
      console.log(`Finder ${view}: ${name}: passed`);
    }
    await client.request('release');
  }
  console.log(`Passed 19 live control cases; evidence: ${base}`);
} finally {
  await client.request('release').catch(() => {});
  let cleanupError;
  if (finderWindowID) {
    try {
      const snapshot = await observe('Finder', title);
      const window = snapshot.surface.windows.find(w => w.window_id === finderWindowID);
      const close = window && flat(window.tree).find(n => n.subrole === 'AXCloseButton');
      assert.ok(close?.frame, 'Owned Finder close control unavailable');
      records.push({ test: 'owned Finder cleanup', result: await act({ kind: 'click', at: point(close) }) });
      await client.request('release');
      assert.ok(!osa('JSON.stringify(Application("Finder").windows().map(w => w.id()))').includes(finderWindowID));
    } catch (error) { cleanupError = error; }
    finally { await client.request('release').catch(() => {}); }
  }
  client.close();
  if (fixture?.exitCode === null && fixture.signalCode === null) fixture.kill('SIGTERM');
  await writeFile(join(base, 'results.json'), JSON.stringify(records, null, 2));
  if (cleanupError) throw cleanupError;
}
