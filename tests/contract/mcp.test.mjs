import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Host } from '../../packages/host/server.mjs';
import { Broker } from '../../packages/host/broker.mjs';
test('real stdio adapter discovers schemas and routes tools through shared host', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'ocu-mcp-'));
  const calls = [];
  const backend = { async call(name, args) { calls.push({ name, args }); return { content: [{ type: 'text', text: 'fixture result' }] }; }, async stop() {}, async reset() {} };
  const host = new Host({ directory, broker: backend }); await host.start();
  const client = new Broker(process.execPath, ['packages/cli/main.mjs', 'mcp'], { ...process.env, OCU_RUNTIME_DIR: directory });
  t.after(async () => { await client.stop(); await host.close(); await rm(directory, { recursive: true, force: true }); });
  const listing = await client.list();
  assert.deepEqual(listing.tools.map(t => t.name).sort(), ['computer_use_observe', 'computer_use_action_batch', 'computer_use_permissions', 'computer_use_list_apps', 'computer_use_release', 'computer_use_status'].sort());
  const result = await client.call('computer_use_observe', { app_target: 'Fixture' });
  assert.equal(result.content[0].text, 'fixture result'); assert.equal(calls[0].name, 'use_observe');
  const invalid = await client.call('computer_use_action_batch', { actions: [{ kind: 'click', at: { x: 'wrong', y: 1 } }] });
  assert.equal(invalid.isError, true); assert.equal(calls.length, 1);
  await client.call('computer_use_release', {}); assert.equal(host.owner, null);
});

test('large observations pass through the host and MCP adapter without shortening', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'ocu-output-'));
  const text = 'snapshot:\n' + '  arbitrary_application_text: "λ😀 unchanged"\n'.repeat(4000);
  const backend = { async call() { return { content: [{ type: 'text', text }] }; }, async stop() {}, async reset() {} };
  const host = new Host({ directory, broker: backend }); await host.start();
  const client = new Broker(process.execPath, ['packages/cli/main.mjs', 'mcp'], { ...process.env, OCU_RUNTIME_DIR: directory });
  t.after(async () => { await client.stop(); await host.close(); await rm(directory, { recursive: true, force: true }); });
  const result = await client.call('computer_use_observe', { app_target: 'Fixture' });
  assert.equal(result.content.length, 1);
  assert.equal(result.content[0].text, text);
  await client.call('computer_use_release', {});
});
