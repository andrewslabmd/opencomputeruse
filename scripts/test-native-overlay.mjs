import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { resolve, join } from 'node:path';
import { parse } from 'yaml';
import { Client } from '../packages/cli/client.mjs';
import { runtimeDirectory } from '../packages/protocol/index.mjs';

// Opt-in live acceptance for the agent cursor overlay, against the installed,
// running app and an owned accessory fixture launched in the background. It
// checks that the agent's overlay is stacked directly above the target window
// with the published cursor, that input still reaches the target through it,
// that it disappears on release, and that the foreground never changes. It
// also captures the overlay window itself for visual review.
if (!process.argv.includes('--interactive')) throw new Error('Overlay acceptance requires --interactive authorization');
const dir = resolve(`work/native-overlay-${Date.now()}`);
const app = join(dir, 'ClickFixture.app'), statePath = join(dir, 'state.json'), lister = join(dir, 'windows');
await mkdir(join(app, 'Contents/MacOS'), { recursive: true });
execFileSync('xcrun', ['swiftc', 'tests/native-fixtures/ClickFixture.swift', '-o', join(app, 'Contents/MacOS/ClickFixture')]);
await writeFile(join(app, 'Contents/Info.plist'), `<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleName</key><string>ClickFixture</string><key>CFBundleExecutable</key><string>ClickFixture</string><key>CFBundleIdentifier</key><string>com.andrewslabmd.opencomputeruse.clickfixture</string><key>CFBundlePackageType</key><string>APPL</string><key>LSUIElement</key><true/></dict></plist>`);
// Front-to-back on-screen windows: number, owner pid and bounds.
await writeFile(join(dir, 'windows.swift'), `import CoreGraphics
import Foundation
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
let out = list.map { w -> [String: Any] in ["id": w[kCGWindowNumber as String] ?? 0, "pid": w[kCGWindowOwnerPID as String] ?? 0, "layer": w[kCGWindowLayer as String] ?? 0, "bounds": w[kCGWindowBounds as String] ?? [:]] }
print(String(data: try! JSONSerialization.data(withJSONObject: out), encoding: .utf8)!)
`);
execFileSync('xcrun', ['swiftc', join(dir, 'windows.swift'), '-o', lister]);
execFileSync('open', ['-g', '-n', app, '--args', statePath]);

const sleep = ms => new Promise(r => setTimeout(r, ms));
const state = async () => JSON.parse(await readFile(statePath, 'utf8'));
const windows = () => JSON.parse(execFileSync(lister, { encoding: 'utf8' }));
const ocuPid = Number(execFileSync('pgrep', ['-f', 'OpenComputerUse Dev.app/Contents/MacOS/OpenComputerUse$'], { encoding: 'utf8' }).trim().split('\n')[0]);
const cursors = async () => JSON.parse(await readFile(join(runtimeDirectory(), 'cursors.json'), 'utf8'));
async function until(predicate, label) {
  const readyBy = Date.now() + 10000; let last; // Harness readiness only.
  while (Date.now() < readyBy) { try { last = await predicate(); if (last) return last; } catch {} await sleep(50); }
  throw Error(`Not reached: ${label}`);
}
const flat = n => [n, ...(n.children ?? []).flatMap(flat)];
const nodes = r => r.snapshot.surface.windows.flatMap(w => flat(w.tree));
const client = new Client();
const cases = [];
const pass = label => { cases.push(label); console.log(`${label}: passed`); };
let pid;
try {
  const fixture = await until(async () => { const s = await state(); return s.pid > 0 && s; }, 'fixture launched');
  pid = fixture.pid;
  await client.connect('Overlay acceptance');
  const call = async (name, args) => { const raw = await client.request('tools/call', { name, arguments: args }); assert.notEqual(raw.isError, true, JSON.stringify(raw)); return parse(raw.content.find(x => x.type === 'text').text); };
  const observe = () => call('use_observe', { app_target: `PID:${pid}` });
  // The overlay for this agent: OCU's on-screen window with the fixture window's exact bounds.
  const overlay = list => {
    const target = list.findIndex(w => w.id === fixture.window);
    const panel = list.findIndex(w => w.pid === ocuPid && target >= 0 && JSON.stringify(w.bounds) === JSON.stringify(list[target].bounds));
    return { target, panel, id: list[panel]?.id };
  };
  let r = await observe();
  const actions = [
    ['double-click the pad', r => ({ kind: 'click', element: nodes(r).find(n => n.name === 'Click pad').id, click_count: 2 })],
    ['select a table row', r => ({ kind: 'click', element: nodes(r).find(n => n.role === 'AXRow' && flat(n).some(x => x.name === 'Gamma')).id })],
    ['type into the editor', r => ({ kind: 'type', element: nodes(r).find(n => n.role === 'AXTextField').id, text: 'overlay test', replace: true })],
  ];
  for (const [index, [label, build]] of actions.entries()) {
    r = await observe();
    await call('use_action_batch', { actions: [build(r)] });
    const cursor = await until(async () => (await cursors()).find(c => c.name === 'Overlay acceptance' && c.pid === pid), 'cursor published');
    assert.equal(cursor.window_id, fixture.window);
    const placed = await until(async () => { const o = overlay(windows()); return o.panel >= 0 && o.panel === o.target - 1 && o; }, 'overlay directly above the target');
    await sleep(600); // let the glide and ripple finish before capturing
    execFileSync('screencapture', ['-x', '-o', '-l', String(placed.id), join(dir, `overlay-${index + 1}.png`)]);
    execFileSync('screencapture', ['-x', '-o', '-l', String(fixture.window), join(dir, `target-${index + 1}.png`)]);
    pass(`${label}: cursor published for the target window and overlay stacked directly above it`);
  }
  const s = await until(async () => { const s = await state(); return s.clicks.length >= 2 && s.editor === 'overlay test' && s.selection.includes(2) && s; }, 'input reached the target');
  assert.deepEqual(s.clicks.slice(0, 2).map(c => c.count), [1, 2]);
  pass('clicks, selection and typing reached the target through the overlay');
  await client.request('release');
  await until(async () => !(await cursors()).some(c => c.name === 'Overlay acceptance'), 'cursor withdrawn');
  await until(async () => overlay(windows()).panel < 0, 'overlay removed');
  pass('release withdraws the cursor and removes the overlay');
  const final = await state();
  assert.ok(!final.foreground_changes.some(c => c.to === pid), 'The fixture never came to the front');
  assert.ok(!final.foreground_changes.some(c => c.to === ocuPid), 'OpenComputerUse never came to the front');
  pass('neither the fixture nor OpenComputerUse came to the front');
  await writeFile(join(dir, 'acceptance.json'), JSON.stringify({ passed: true, cases, final }, null, 2));
  console.log(`Evidence: ${dir}`);
} finally {
  await client.request('release').catch(() => {}); client.close();
  if (pid) { try { process.kill(pid); } catch {} }
}
