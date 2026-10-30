import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { resolve, join } from 'node:path';
import { parse } from 'yaml';
import { Client } from '../packages/cli/client.mjs';

// Opt-in live acceptance: repeated and modified pointer clicks, perform_action
// and list_apps against an owned accessory fixture launched in the background.
// The fixture records what AppKit delivered and audits the foreground every 10 ms.
if (!process.argv.includes('--interactive')) throw new Error('Native click acceptance requires --interactive authorization');
const dir = resolve(`work/native-clicks-${Date.now()}`);
const app = join(dir, 'ClickFixture.app'), statePath = join(dir, 'state.json');
await mkdir(join(app, 'Contents/MacOS'), { recursive: true });
execFileSync('xcrun', ['swiftc', 'tests/native-fixtures/ClickFixture.swift', '-o', join(app, 'Contents/MacOS/ClickFixture')]);
await writeFile(join(app, 'Contents/Info.plist'), `<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleName</key><string>ClickFixture</string><key>CFBundleExecutable</key><string>ClickFixture</string><key>CFBundleIdentifier</key><string>com.andrewslabmd.opencomputeruse.clickfixture</string><key>CFBundlePackageType</key><string>APPL</string><key>LSUIElement</key><true/></dict></plist>`);
// LaunchServices in the background: the fixture never takes the front.
execFileSync('open', ['-g', '-n', app, '--args', statePath]);
const client = new Client();
const records = [], cases = [];
const sleep = ms => new Promise(r => setTimeout(r, ms));
const state = async () => JSON.parse(await readFile(statePath, 'utf8'));
async function until(predicate, label) {
  const readyBy = Date.now() + 10000; // Harness readiness only.
  let last;
  while (Date.now() < readyBy) { try { last = await state(); if (predicate(last)) return last; } catch {} await sleep(40); }
  throw Error(`Fixture state did not reach: ${label}\n${JSON.stringify(last)}`);
}
const flat = n => [n, ...(n.children ?? []).flatMap(flat)];
const nodes = r => r.snapshot.surface.windows.flatMap(w => flat(w.tree));
const texts = n => flat(n).flatMap(x => [x.name, x.value]).filter(Boolean);
async function call(name, args) {
  const raw = await client.request('tools/call', { name, arguments: args });
  assert.notEqual(raw.isError, true, JSON.stringify(raw));
  const text = raw.content.find(x => x.type === 'text').text;
  const result = name === 'use_list_apps' ? JSON.parse(text) : parse(text);
  records.push({ name, args, result, actual: await state() });
  await writeFile(join(dir, 'results.json'), JSON.stringify(records, null, 2));
  return result;
}
let pid;
const observe = () => call('use_observe', { app_target: `PID:${pid}` });
const act = action => call('use_action_batch', { actions: [action], diagnostics: true }).then(r => r.actions[0]);
const pass = label => { cases.push(label); console.log(`${label}: passed`); };
const row = (r, label) => nodes(r).find(n => n.role === 'AXRow' && texts(n).includes(label));
try {
  pid = (await until(s => s.pid > 0, 'launched')).pid;
  await client.connect('Native click and action acceptance');
  const host = await client.request('status'); assert.ok(!host.busy && !host.owner && !host.paused, JSON.stringify(host));

  const listed = await call('use_list_apps', {});
  const entry = listed.applications.find(a => a.pid === pid);
  assert.ok(entry, 'The background accessory fixture must be listed');
  assert.equal(entry.bundle_id, 'com.andrewslabmd.opencomputeruse.clickfixture'); assert.notEqual(entry.frontmost, true);
  assert.ok(entry.windows.some(w => w.title === 'OCU click fixture' && w.on_screen && w.window_id === (listed && records.at(-1).actual.window)), JSON.stringify(entry));
  // None while the login window is in front (a locked Mac): it is not a listed app.
  assert.ok(listed.applications.filter(a => a.frontmost).length <= 1, 'At most one app is marked frontmost');
  assert.equal((await client.request('status')).owner, null, 'Listing must not take the workflow');
  pass('list_apps lists the background fixture and its window without taking ownership');

  let r = await observe();
  const pad = () => nodes(r).find(n => n.name === 'Click pad');
  let a = await act({ kind: 'click', element: pad().id, click_count: 2 });
  assert.ok(['sent', 'unconfirmed'].includes(a.status), JSON.stringify(a));
  assert.equal(a.native_operations[0].name, 'LeftDoubleClick');
  let s = await until(s => s.clicks.length === 2, 'double click');
  assert.deepEqual(s.clicks.map(c => c.count), [1, 2]); assert.ok(s.clicks.every(c => c.modifiers.length === 0)); assert.equal(s.presses, 0);
  pass('double-click delivers click counts 1, 2 to the view, not AXPress');

  r = await observe();
  a = await act({ kind: 'click', element: pad().id, click_count: 3, modifiers: ['cmd', 'shift'] });
  assert.equal(a.native_operations[0].name, 'Shift+Cmd+LeftTripleClick', JSON.stringify(a));
  s = await until(s => s.clicks.length === 5, 'triple click');
  assert.deepEqual(s.clicks.slice(2).map(c => c.count), [1, 2, 3]);
  assert.ok(s.clicks.slice(2).every(c => c.modifiers.join() === 'cmd,shift' && c.global_modifiers.length === 0), JSON.stringify(s.clicks));
  pass('triple-click carries Cmd+Shift on the events while the global modifier state stays clear');

  r = await observe();
  a = await act({ kind: 'click', element: row(r, 'Alpha').id });
  await until(s => s.selection.join() === '0', 'select Alpha');
  r = await observe();
  a = await act({ kind: 'click', element: row(r, 'Gamma').id, modifiers: ['cmd'] });
  assert.ok(['sent', 'unconfirmed'].includes(a.status), JSON.stringify(a));
  await until(s => s.selection.join() === '0,2', 'cmd-click adds Gamma');
  pass('Cmd-click adds a row to an NSTableView selection');
  r = await observe();
  a = await act({ kind: 'click', element: row(r, 'Epsilon').id, modifiers: ['shift'] });
  s = await until(s => [2, 3, 4].every(i => s.selection.includes(i)), 'shift-click extends to Epsilon');
  pass(`Shift-click extends the selection (${s.selection.join(',')})`);
  r = await observe();
  a = await act({ kind: 'click', element: row(r, 'Beta').id, click_count: 2 });
  await until(s => s.double_clicked_rows.join() === '1', 'double action on Beta');
  pass("Double-click fires the table's double action on the clicked row");

  r = await observe();
  const stepper = nodes(r).find(n => n.role === 'AXIncrementor');
  a = await act({ kind: 'perform_action', element: stepper.id });
  assert.equal(a.behavior, 'list_actions'); assert.equal(a.native_operations.length, 0);
  assert.ok(a.supported[0].actions.includes('AXIncrement'), JSON.stringify(a.supported));
  assert.equal((await state()).stepper, 3);
  a = await act({ kind: 'perform_action', element: stepper.id, name: 'AXIncrement' });
  assert.equal(a.status, 'completed', JSON.stringify(a));
  await until(s => s.stepper === 4, 'stepper incremented');
  pass('perform_action lists without sending, then AXIncrement steps the stepper');

  r = await observe();
  const card = nodes(r).find(n => n.name === 'Archive card');
  a = await act({ kind: 'perform_action', element: card.id });
  const archive = a.supported[0].actions.find(x => /Archive/.test(x));
  assert.ok(archive, JSON.stringify(a.supported));
  a = await act({ kind: 'perform_action', element: card.id, name: archive });
  assert.equal(a.status, 'completed', JSON.stringify(a));
  await until(s => s.archives === 1, 'custom action');
  pass('perform_action invokes an app custom action by its listed name');

  r = await observe();
  a = await act({ kind: 'perform_action', element: card.id, name: 'AXIncrement' });
  assert.equal(a.status, 'failed'); assert.equal(a.code, 'unsupported_native_action'); assert.equal(a.effect, 'not_attempted');
  pass('an action the target does not advertise is refused before anything is sent');

  r = await observe();
  a = await act({ kind: 'perform_action', element: pad().id, name: 'AXShowMenu' });
  assert.ok(['pending', 'completed'].includes(a.status), JSON.stringify(a));
  await until(s => s.menu_opened === 1, 'context menu opened');
  r = await observe();
  const menu = nodes(r).find(n => n.role === 'AXMenu');
  assert.ok(menu, 'The opened menu is observed');
  a = await act({ kind: 'perform_action', element: menu.id, name: 'AXCancel' });
  assert.equal(a.status, 'completed', JSON.stringify(a));
  assert.equal(a.effect, 'menu_dismissed');
  assert.ok(a.native_operations.some(op => op.kind === 'keyboard' && op.name === 'Escape'));
  await until(s => s.menu_closed === 1, 'menu closed by exact-menu Escape');
  pass('menu AXCancel dispatches exact-menu Escape and verifies dismissal');

  await client.request('release');
  const final = await state();
  // The user may switch apps during the run. OCU's fault is the fixture coming to
  // the front, or the guard catching an app that jumped forward after OCU's input.
  const guard = records.flatMap(r => (r.result.actions ?? []).flatMap(x => x.foreground_guard ?? []));
  assert.ok(!final.foreground_changes.some(c => c.to === pid), 'The fixture never came to the front');
  assert.notEqual(final.frontmost_pid, pid);
  assert.deepEqual(guard.filter(g => g.outcome !== 'user_switch'), [], 'No app jumped to the front because of OCU input');
  pass('the fixture never came to the front and no app jumped forward because of OCU input');
  if (final.foreground_changes.length) console.log(`Foreground changes by the user during the run: ${final.foreground_changes.length}`);
  // Reported, not asserted: the user may move the mouse during the run, and
  // the cursor position cannot tell their movement from OCU's.
  console.log(`Physical pointer position changed during the run: ${final.pointer_moved}`);
  await writeFile(join(dir, 'acceptance.json'), JSON.stringify({ passed: true, cases, final, records: records.length }, null, 2));
  console.log(`Evidence: ${dir}`);
} finally {
  await client.request('release').catch(() => {}); client.close();
  if (pid) { try { process.kill(pid); } catch {} }
}
