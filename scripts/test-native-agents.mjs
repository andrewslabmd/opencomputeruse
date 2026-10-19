import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { resolve, join } from 'node:path';
import { parse } from 'yaml';
import { Client } from '../packages/cli/client.mjs';

// Opt-in live acceptance for concurrent agents: two clients, each with its own
// owned accessory fixture launched in the background. Both work at the same
// time (observations, pointer clicks, keyboard text), each app keeps its own
// background activation, a claimed app is refused to the other agent, and no
// input reaches the other fixture. Each fixture audits the foreground every 10 ms.
if (!process.argv.includes('--interactive')) throw new Error('Concurrent agent acceptance requires --interactive authorization');
const dir = resolve(`work/native-agents-${Date.now()}`);
const app = join(dir, 'ClickFixture.app');
await mkdir(join(app, 'Contents/MacOS'), { recursive: true });
execFileSync('xcrun', ['swiftc', 'tests/native-fixtures/ClickFixture.swift', '-o', join(app, 'Contents/MacOS/ClickFixture')]);
await writeFile(join(app, 'Contents/Info.plist'), `<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleName</key><string>ClickFixture</string><key>CFBundleExecutable</key><string>ClickFixture</string><key>CFBundleIdentifier</key><string>com.andrewslabmd.opencomputeruse.clickfixture</string><key>CFBundlePackageType</key><string>APPL</string><key>LSUIElement</key><true/></dict></plist>`);
const sleep = ms => new Promise(r => setTimeout(r, ms));
const flat = n => [n, ...(n.children ?? []).flatMap(flat)];
const nodes = r => r.snapshot.surface.windows.flatMap(w => flat(w.tree));
const records = [], cases = [];
const pass = label => { cases.push(label); console.log(`${label}: passed`); };

function agent(name) {
  const statePath = join(dir, `${name}.json`);
  execFileSync('open', ['-g', '-n', app, '--args', statePath]);
  const client = new Client();
  const self = {
    name, client, pid: 0,
    state: async () => JSON.parse(await readFile(statePath, 'utf8')),
    async until(predicate, label) {
      const readyBy = Date.now() + 10000; let last; // Harness readiness only.
      while (Date.now() < readyBy) { try { last = await self.state(); if (predicate(last)) return last; } catch {} await sleep(40); }
      throw Error(`${name} did not reach: ${label}\n${JSON.stringify(last)}`);
    },
    async raw(tool, args) { return client.request('tools/call', { name: tool, arguments: args }); },
    async call(tool, args) {
      const raw = await self.raw(tool, args);
      assert.notEqual(raw.isError, true, `${name}: ${JSON.stringify(raw)}`);
      const result = parse(raw.content.find(x => x.type === 'text').text);
      records.push({ agent: name, tool, args, result, at: Date.now() });
      return result;
    },
    observe: () => self.call('use_observe', { app_target: `PID:${self.pid}` }),
    async act(build) {
      const r = await self.observe();
      const result = (await self.call('use_action_batch', { actions: [build(r)], diagnostics: true })).actions[0];
      assert.ok(!['failed'].includes(result.status), `${name}: ${JSON.stringify(result)}`);
      assert.notEqual(result.code, 'input_isolation_violation');
      for (const receipt of result.input_delivery ?? []) {
        assert.equal(receipt.target_pid, self.pid); assert.ok(receipt.received_pids.every(p => p === self.pid), JSON.stringify(receipt));
      }
      return result;
    },
  };
  return self;
}
const a = agent('agent-a'), b = agent('agent-b');
try {
  a.pid = (await a.until(s => s.pid > 0, 'launched')).pid; b.pid = (await b.until(s => s.pid > 0, 'launched')).pid;
  assert.notEqual(a.pid, b.pid);
  await a.client.connect('Agent A (concurrency acceptance)'); await b.client.connect('Agent B (concurrency acceptance)');
  const host = await a.client.request('status'); assert.ok(!host.busy && !host.paused && host.workflows.length === 0, JSON.stringify(host));

  await Promise.all([a.observe(), b.observe()]);
  const status = await a.client.request('status');
  assert.deepEqual(status.workflows.map(w => w.app_pid).sort(), [a.pid, b.pid].sort());
  pass('two agents observe two apps at the same time and each holds its own app');

  const refused = await b.raw('use_observe', { app_target: `PID:${a.pid}` }).catch(error => error);
  assert.equal(refused.code, 'busy', JSON.stringify(refused));
  assert.deepEqual((await b.client.request('status')).workflows.find(w => w.app_pid === b.pid) ? true : false, true);
  pass("an agent asking for the other agent's app is refused, and keeps its own");

  const pad = r => nodes(r).find(n => n.name === 'Click pad');
  const editor = r => nodes(r).find(n => n.role === 'AXTextField');
  for (let round = 1; round <= 4; round++) {
    const [clicker, typist] = round % 2 ? [a, b] : [b, a];
    const before = await Promise.all([clicker.state(), typist.state()]);
    const text = `${typist.name}-round-${round}`;
    await Promise.all([
      clicker.act(r => ({ kind: 'click', element: pad(r).id, click_count: 2, modifiers: ['cmd'] })),
      typist.act(r => ({ kind: 'type', element: editor(r).id, text, replace: true })),
    ]);
    const after = [await clicker.until(s => s.clicks.length === before[0].clicks.length + 2, 'own double click'),
      await typist.until(s => s.editor === text, 'own text')];
    assert.deepEqual(after[0].clicks.slice(-2).map(c => [c.count, c.modifiers.join()]), [[1, 'cmd'], [2, 'cmd']]);
    assert.equal(after[1].clicks.length, before[1].clicks.length, 'No click reached the typing agent\'s app');
    assert.equal(after[0].editor, before[0].editor, 'No text reached the clicking agent\'s app');
    pass(`round ${round}: ${clicker.name} double-clicks while ${typist.name} types; each app gets only its own input`);
  }

  const [sa, sb] = await Promise.all([a.state(), b.state()]);
  assert.equal(sa.active, true); assert.equal(sb.active, true);
  pass('both apps hold their own background activation at the same time');

  await a.client.request('release');
  await a.until(s => s.active === false, 'A deactivated on release');
  assert.equal((await b.state()).active, true, "B's activation survives A's release");
  await b.act(r => ({ kind: 'click', element: pad(r).id, click_count: 2 }));
  pass("releasing one agent restores only its app; the other keeps working");
  await b.client.request('release');
  await b.until(s => s.active === false, 'B deactivated on release');

  const finals = await Promise.all([a.state(), b.state()]);
  // The user may switch apps during the run. OCU's fault is a fixture coming to
  // the front, or the guard catching an app that jumped forward after OCU's input.
  const guard = records.flatMap(r => (r.result.actions ?? []).flatMap(x => x.foreground_guard ?? []));
  for (const s of finals) {
    assert.ok(!s.foreground_changes.some(c => c.to === a.pid || c.to === b.pid), 'A fixture never came to the front');
    assert.notEqual(s.frontmost_pid, s.pid);
  }
  assert.deepEqual(guard.filter(g => g.outcome !== 'user_switch'), [], 'No app jumped to the front because of OCU input');
  pass('no fixture came to the front and no app jumped forward because of OCU input');
  const userSwitches = finals[0].foreground_changes.length;
  if (userSwitches) console.log(`Foreground changes by the user during the run: ${userSwitches} (guard: ${guard.map(g => g.outcome).join(', ') || 'none attributed'})`);
  console.log(`Physical pointer position changed during the run: ${finals.map(s => s.pointer_moved).join(', ')} (user activity cannot be separated from OCU's)`);
  await writeFile(join(dir, 'acceptance.json'), JSON.stringify({ passed: true, cases, finals, records: records.length }, null, 2));
  console.log(`Evidence: ${dir}`);
} finally {
  await writeFile(join(dir, 'results.json'), JSON.stringify(records, null, 2)).catch(() => {});
  for (const x of [a, b]) { await x.client.request('release').catch(() => {}); x.client.close(); if (x.pid) { try { process.kill(x.pid); } catch {} } }
}
