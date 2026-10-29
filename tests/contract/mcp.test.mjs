import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { Host } from '../../packages/host/server.mjs';
import { Broker } from '../../packages/host/broker.mjs';

test('source and compiled MCP handshakes report the app release version', async t => {
  const root = fileURLToPath(new URL('../..', import.meta.url));
  const { version } = JSON.parse(await readFile(join(root, 'package.json'), 'utf8'));
  const directory = await mkdtemp(join(tmpdir(), 'ocu-version-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const executable = join(directory, 'ocu');
  // Compile the same CLI entry point as scripts/build.mjs, for the test host.
  const build = spawnSync(join(root, 'node_modules/.bin/bun'), ['build', '--compile', 'packages/cli/main.mjs', '--outfile', executable], { cwd: root, encoding: 'utf8', timeout: 60_000 });
  assert.ifError(build.error);
  assert.equal(build.status, 0, build.stderr);
  for (const [command, args] of [[process.execPath, [join(root, 'packages/cli/main.mjs'), 'mcp']], [executable, ['mcp']]]) {
    // Initialize needs no host or native actions. Run away from the checkout;
    // the compiled executable must carry its version without a package.json.
    const response = spawnSync(command, args, {
      cwd: directory, encoding: 'utf8', timeout: 10_000,
      env: { ...process.env, OCU_RUNTIME_DIR: directory },
      input: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'initialize', params: { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'version-test', version: '1' } } }) + '\n',
    });
    assert.ifError(response.error);
    assert.equal(response.status, 0, response.stderr);
    const message = JSON.parse(response.stdout.trim());
    assert.equal(message.id, 1);
    assert.deepEqual(message.result.serverInfo, { name: 'opencomputeruse', version });
  }
});

test('real stdio adapter discovers schemas and routes tools through shared host', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'ocu-mcp-'));
  const calls = [];
  const backend = { async call(name, args) { calls.push({ name, args }); return { content: [{ type: 'text', text: 'fixture result' }] }; }, async stop() {}, async reset() {} };
  const host = new Host({ directory, broker: backend }); await host.start();
  const client = new Broker(process.execPath, ['packages/cli/main.mjs', 'mcp'], { ...process.env, OCU_RUNTIME_DIR: directory });
  t.after(async () => { await client.stop(); await host.close(); await rm(directory, { recursive: true, force: true }); });
  const listing = await client.list();
  assert.deepEqual(listing.tools.map(t => t.name).sort(), ['computer_use_observe', 'computer_use_action_batch', 'computer_use_permissions', 'computer_use_list_apps', 'computer_use_release', 'computer_use_status', 'report_issue'].sort());
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
