import test from 'node:test';
import assert from 'node:assert/strict';
import { chmod, mkdir, mkdtemp, readFile, stat, symlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Writable } from 'node:stream';
import { context, connect, disconnect, ocuPath, runSetup, snippet, statusAll } from '../../packages/cli/setup.mjs';

const OCU = '/Applications/Open Computer Use.app/Contents/MacOS/ocu';
const OLD = '/Users/someone/Downloads/Open Computer Use.app/Contents/MacOS/ocu';

// A fake home with fake agent commands. Claude's and Codex's own `mcp`
// commands are simulated: Claude's writes its user settings, as the real one does.
async function home({ agents = [] } = {}) {
  const root = await mkdtemp(join(tmpdir(), 'ocu-setup-test-'));
  const bin = join(root, 'bin'); await mkdir(bin);
  for (const name of agents.filter(a => ['claude', 'codex', 'opencode', 'cursor-agent'].includes(a))) { await writeFile(join(bin, name), '#!/bin/sh\n'); await chmod(join(bin, name), 0o755); }
  const codex = new Map(), calls = [];
  const claudeFile = join(root, '.claude.json');
  const run = async (cmd, args) => {
    calls.push([cmd.split('/').pop(), ...args]);
    const [, verb] = args;
    if (cmd.endsWith('/claude')) {
      const settings = JSON.parse(await readFile(claudeFile, 'utf8').catch(() => '{}'));
      settings.mcpServers ??= {};
      if (verb === 'add') { if (settings.mcpServers[args[4]]) return { code: 1, stdout: '', stderr: 'already exists' }; settings.mcpServers[args[4]] = { type: 'stdio', command: args[6], args: args.slice(7), env: {} }; }
      if (verb === 'remove') delete settings.mcpServers[args[4]];
      await writeFile(claudeFile, JSON.stringify(settings));
      return { code: 0, stdout: '', stderr: '' };
    }
    if (verb === 'get') return codex.has(args[2]) ? { code: 0, stdout: JSON.stringify({ name: args[2], transport: { type: 'stdio', command: codex.get(args[2])[0], args: codex.get(args[2]).slice(1) } }), stderr: '' } : { code: 1, stdout: '', stderr: 'not found' };
    if (verb === 'add') codex.set(args[2], args.slice(4));
    if (verb === 'remove') codex.delete(args[2]);
    return { code: 0, stdout: '', stderr: '' };
  };
  const applications = join(root, 'Applications'); await mkdir(applications);
  if (agents.includes('cursor')) await mkdir(join(applications, 'Cursor.app'));
  if (agents.includes('opencode-config')) await mkdir(join(root, '.config/opencode'), { recursive: true });
  const ctx = context({ home: root, env: { PATH: '' }, run, ocu: OCU });
  ctx.searchPath = [bin]; ctx.applications = [applications];
  return { root, ctx, codex, calls, claudeFile };
}
const byId = agents => Object.fromEntries(agents.map(a => [a.id, a.status]));

test('status lists every agent; only installed ones can be connected', async () => {
  const { ctx } = await home({ agents: ['claude', 'cursor'] });
  assert.deepEqual(byId(await statusAll(ctx, OCU)), { claude: 'available', codex: 'not_installed', cursor: 'available', opencode: 'not_installed' });
  await assert.rejects(connect(ctx, 'codex', OCU), /Codex was not found/);
});

test('Claude Code and Codex are connected through their own commands, at user scope', async () => {
  const { ctx, calls, claudeFile, codex } = await home({ agents: ['claude', 'codex'] });
  assert.equal((await connect(ctx, 'claude', OCU)).status, 'connected');
  assert.equal((await connect(ctx, 'codex', OCU)).status, 'connected');
  assert.deepEqual(calls.filter(c => c[2] === 'add'), [
    ['claude', 'mcp', 'add', '--scope', 'user', 'opencomputeruse', '--', OCU, 'mcp'],
    ['codex', 'mcp', 'add', 'opencomputeruse', '--', OCU, 'mcp'],
  ]);
  assert.deepEqual(JSON.parse(await readFile(claudeFile, 'utf8')).mcpServers.opencomputeruse.args, ['mcp']);
  assert.deepEqual(codex.get('opencomputeruse'), [OCU, 'mcp']);
  // Connecting again changes nothing.
  const before = calls.length;
  await connect(ctx, 'claude', OCU);
  assert.equal(calls.filter((c, i) => i >= before && c[2] !== 'get').length, 0);
});

test('an entry for another copy of the app is outdated and replaced on connect', async () => {
  const { ctx, claudeFile } = await home({ agents: ['claude'] });
  await writeFile(claudeFile, JSON.stringify({ mcpServers: { opencomputeruse: { type: 'stdio', command: OLD, args: ['mcp'] }, other: { command: 'x' } } }));
  assert.equal(byId(await statusAll(ctx, OCU)).claude, 'outdated');
  assert.equal((await connect(ctx, 'claude', OCU)).status, 'connected');
  const servers = JSON.parse(await readFile(claudeFile, 'utf8')).mcpServers;
  assert.equal(servers.opencomputeruse.command, OCU);
  assert.deepEqual(servers.other, { command: 'x' });
  assert.equal((await disconnect(ctx, 'claude', OCU)).status, 'available');
});

test('Cursor settings keep other servers and comments, with a backup and the original mode', async () => {
  const { ctx, root } = await home({ agents: ['cursor'] });
  const file = join(root, '.cursor/mcp.json');
  await mkdir(join(root, '.cursor'));
  const original = '{\n  // mine\n  "mcpServers": {\n    "other": { "command": "x" },\n  }\n}\n';
  await writeFile(file, original, { mode: 0o600 });
  await connect(ctx, 'cursor', OCU);
  const text = await readFile(file, 'utf8');
  assert.match(text, /\/\/ mine/); assert.match(text, /"other"/);
  assert.match(text, /"opencomputeruse": \{\n\s+"type": "stdio",\n\s+"command": "\/Applications\/Open Computer Use\.app\/Contents\/MacOS\/ocu",\n\s+"args": \[\n\s+"mcp"\n\s+\]/);
  assert.equal(await readFile(`${file}.ocu-backup`, 'utf8'), original);
  assert.equal((await stat(file)).mode & 0o777, 0o600);
  assert.equal(byId(await statusAll(ctx, OCU)).cursor, 'connected');
  await disconnect(ctx, 'cursor', OCU);
  assert.doesNotMatch(await readFile(file, 'utf8'), /opencomputeruse/);
});

test('a settings file that is a symlink is edited where it points, and stays a link', async () => {
  const { ctx, root } = await home({ agents: ['cursor'] });
  await mkdir(join(root, 'dotfiles')); await mkdir(join(root, '.cursor'));
  await writeFile(join(root, 'dotfiles/mcp.json'), '{}');
  await symlink(join(root, 'dotfiles/mcp.json'), join(root, '.cursor/mcp.json'));
  await connect(ctx, 'cursor', OCU);
  assert.match(await readFile(join(root, 'dotfiles/mcp.json'), 'utf8'), /opencomputeruse/);
});

test('OpenCode: an existing opencode.jsonc is used; a new config gets the schema and a local server', async () => {
  const jsonc = await home({ agents: ['opencode-config'] });
  const file = join(jsonc.root, '.config/opencode/opencode.jsonc');
  await writeFile(file, '{\n  // keep\n  "$schema": "https://opencode.ai/config.json"\n}\n');
  await connect(jsonc.ctx, 'opencode', OCU);
  const text = await readFile(file, 'utf8');
  assert.match(text, /\/\/ keep/);
  assert.deepEqual(JSON.parse(text.replace('// keep', '')).mcp.opencomputeruse, { type: 'local', command: [OCU, 'mcp'], enabled: true });

  const fresh = await home({ agents: ['opencode'] });
  await connect(fresh.ctx, 'opencode', OCU);
  const created = JSON.parse(await readFile(join(fresh.root, '.config/opencode/opencode.json'), 'utf8'));
  assert.equal(created.$schema, 'https://opencode.ai/config.json');
  assert.deepEqual(created.mcp.opencomputeruse.command, [OCU, 'mcp']);
});

test('an unreadable settings file is reported and left untouched', async () => {
  const { ctx, root } = await home({ agents: ['cursor'] });
  await mkdir(join(root, '.cursor'));
  await writeFile(join(root, '.cursor/mcp.json'), '{ "mcpServers": ');
  assert.equal(byId(await statusAll(ctx, OCU)).cursor, 'error');
  await assert.rejects(connect(ctx, 'cursor', OCU), /could not be read.*ocu setup --print/);
  assert.equal(await readFile(join(root, '.cursor/mcp.json'), 'utf8'), '{ "mcpServers": ');
});

test('setup refuses a copy of the app that is not installed, and prints settings for manual setup', async () => {
  const root = await mkdtemp(join(tmpdir(), 'ocu-setup-path-'));
  await writeFile(join(root, 'node'), ''); await assert.rejects(ocuPath(join(root, 'node')), /ocu command/);
  await mkdir(join(root, 'AppTranslocation/x'), { recursive: true }); await writeFile(join(root, 'AppTranslocation/x/ocu'), '');
  await assert.rejects(ocuPath(join(root, 'AppTranslocation/x/ocu')), /Applications folder/);
  assert.match(snippet('claude', OCU), /^claude mcp add --scope user opencomputeruse -- '\/Applications\/Open Computer Use\.app\/Contents\/MacOS\/ocu' mcp$/);
  assert.match(snippet('codex', OCU), /\[mcp_servers\.opencomputeruse\]\ncommand = "\/Applications\/Open Computer Use\.app\/Contents\/MacOS\/ocu"\nargs = \["mcp"\]/);
  assert.match(snippet(undefined, OCU), /"args": \[\n\s+"mcp"/);
});

test('ocu setup --json reports the command agents launch and each agent', async () => {
  const { ctx } = await home({ agents: ['codex'] });
  let text = '';
  const output = new Writable({ write(chunk, _, done) { text += chunk; done(); } });
  assert.equal(await runSetup(['--json'], { ctx, output }), 0);
  const result = JSON.parse(text);
  assert.deepEqual(result.command, [OCU, 'mcp']);
  assert.equal(result.agents.find(a => a.id === 'codex').status, 'available');
  text = '';
  assert.equal(await runSetup(['codex', '--json'], { ctx, output }), 0);
  assert.equal(JSON.parse(text).status, 'connected');
  assert.equal(await runSetup(['nope'], { ctx, output }), 1);
});
