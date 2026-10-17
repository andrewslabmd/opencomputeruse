import { execFileSync } from 'node:child_process';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { resolve, join } from 'node:path';
import { parse } from 'yaml';
import { Client } from '../packages/cli/client.mjs';

// Opt-in demo of agent cursors and the menu-bar indicator: two agents work in
// two owned fixture windows for about a minute, with pauses where an agent
// "thinks". The windows are shown above other windows without taking focus.
// Uses the installed, running app. Run: node scripts/demo-agents.mjs --interactive
if (!process.argv.includes('--interactive')) throw new Error('The demo sends real input to its own fixture windows; run it with --interactive');
const rounds = Number(process.argv.find(a => a.startsWith('--rounds='))?.slice(9) ?? 2);
const dir = resolve(`work/demo-${Date.now()}`);
const app = join(dir, 'ClickFixture.app');
await mkdir(join(app, 'Contents/MacOS'), { recursive: true });
execFileSync('xcrun', ['swiftc', 'tests/native-fixtures/ClickFixture.swift', '-o', join(app, 'Contents/MacOS/ClickFixture')]);
await writeFile(join(app, 'Contents/Info.plist'), `<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleName</key><string>ClickFixture</string><key>CFBundleExecutable</key><string>ClickFixture</string><key>CFBundleIdentifier</key><string>com.andrewslabmd.opencomputeruse.clickfixture</string><key>CFBundlePackageType</key><string>APPL</string><key>LSUIElement</key><true/></dict></plist>`);

const sleep = ms => new Promise(r => setTimeout(r, ms));
const flat = n => [n, ...(n.children ?? []).flatMap(flat)];
const nodes = r => r.snapshot.surface.windows.flatMap(w => flat(w.tree));
const row = (r, label) => nodes(r).find(n => n.role === 'AXRow' && flat(n).some(x => x.name === label)).id;

async function agent(name, originX) {
  const statePath = join(dir, `${name}.json`);
  execFileSync('open', ['-g', '-n', app, '--args', statePath, '--origin', `${originX},330`, '--front']);
  let state; for (let i = 0; i < 100 && !state?.pid; i++) { try { state = JSON.parse(await readFile(statePath, 'utf8')); } catch {} await sleep(50); }
  const client = new Client(); await client.connect(name);
  const call = async (tool, args) => { const raw = await client.request('tools/call', { name: tool, arguments: args }); if (raw.isError) throw Error(raw.content[0].text); return parse(raw.content[0].text); };
  const act = async build => { const r = await call('use_observe', { app_target: `PID:${state.pid}` }); await call('use_action_batch', { actions: [build(r)] }); };
  return { name, pid: state.pid, client, act };
}

async function routine(a, round) {
  const think = ms => sleep(ms);
  const steps = [
    r => ({ kind: 'click', element: row(r, ['Gamma', 'Epsilon'][round % 2]) }),
    r => ({ kind: 'type', element: nodes(r).find(n => n.role === 'AXTextField').id, text: `Hello from ${a.name}`, replace: true }),
    r => ({ kind: 'click', element: nodes(r).find(n => n.name === 'Click pad').id, click_count: 2 }),
    r => ({ kind: 'perform_action', element: nodes(r).find(n => n.role === 'AXIncrementor').id, name: 'AXIncrement' }),
    r => ({ kind: 'click', element: row(r, ['Alpha', 'Delta'][round % 2]) }),
    r => ({ kind: 'type', element: nodes(r).find(n => n.role === 'AXTextField').id, text: `Round ${round + 1} done`, replace: true }),
  ];
  for (const step of steps) { await a.act(step); await think(2200 + Math.random() * 1500); }
}

const agents = [];
try {
  agents.push(await agent('Agent 1', 260), await agent('Agent 2', 780));
  console.log('Two demo windows are up. Watch the cursors and the menu-bar icon.');
  await Promise.all(agents.map(async (a, i) => { await sleep(i * 1300); for (let round = 0; round < rounds; round++) await routine(a, round); }));
  console.log('Demo finished; agents released.');
} finally {
  for (const a of agents) { await a.client.request('release').catch(() => {}); a.client.close(); }
  await sleep(1500);
  for (const a of agents) { try { process.kill(a.pid); } catch {} }
}
