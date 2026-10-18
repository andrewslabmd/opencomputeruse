// Connects Open Computer Use to coding agents. Every agent launches the same
// stdio server (`ocu mcp`); only where each keeps its MCP settings differs.
// Agents with their own setup command are configured through it; the others'
// settings files are edited in place, keeping comments, formatting and any
// other servers.
import { execFile } from 'node:child_process';
import { access, copyFile, mkdir, readFile, realpath, rename, stat, writeFile } from 'node:fs/promises';
import { constants } from 'node:fs';
import { homedir } from 'node:os';
import { basename, delimiter, dirname, join } from 'node:path';
import { applyEdits, modify, parse, printParseErrorCode } from 'jsonc-parser';

export const SERVER = 'opencomputeruse';
const FORMAT = { formattingOptions: { insertSpaces: true, tabSize: 2, eol: '\n' } };

const exists = path => access(path).then(() => true, () => false);
const quote = s => /^[\w@%+=:,./-]+$/.test(s) ? s : `'${s.replaceAll("'", `'\\''`)}'`;

/** The environment setup runs in; tests replace any part of it. */
export function context(overrides = {}) {
  const env = overrides.env ?? process.env;
  const home = overrides.home ?? homedir();
  const ctx = {
    env, home, ocu: overrides.ocu,
    applications: ['/Applications', join(home, 'Applications')],
    // Apps started from Finder get a minimal PATH, so agents installed by
    // Homebrew, npm, Bun or their own installers are looked for there too.
    searchPath: [...(env.PATH ?? '').split(delimiter), join(home, '.local/bin'), '/opt/homebrew/bin', '/usr/local/bin',
      join(home, '.bun/bin'), join(home, '.npm-global/bin'), join(home, '.volta/bin'), join(home, '.opencode/bin'), join(home, 'bin')].filter(Boolean),
    run: overrides.run ?? ((cmd, args) => new Promise(res => execFile(cmd, args, { env: { ...env, PATH: ctx.searchPath.join(delimiter) }, timeout: 30_000 },
      (error, stdout, stderr) => res({ code: error ? (typeof error.code === 'number' ? error.code : 1) : 0, stdout, stderr })))),
    ...overrides,
  };
  return ctx;
}

async function which(ctx, name) {
  for (const dir of ctx.searchPath) {
    const path = join(dir, name);
    try { await access(path, constants.X_OK); if ((await stat(path)).isFile()) return path; } catch {}
  }
  return null;
}

/** The ocu executable agents should launch: this one, wherever the app is installed. */
export async function ocuPath(execPath = process.execPath) {
  const path = await realpath(execPath);
  if (basename(path) !== 'ocu') throw new Error('Run setup from the ocu command inside Open Computer Use.');
  // A translocated or disk-image copy disappears; settings must not point to it.
  if (path.includes('/AppTranslocation/') || path.startsWith('/Volumes/')) throw new Error('Move Open Computer Use to your Applications folder and open it from there, then connect agents.');
  return path;
}

// Settings files: read leniently (JSON with comments), written atomically next
// to a backup of the previous version.
async function readSettings(file) {
  if (!await exists(file)) return { text: null, data: {} };
  const text = await readFile(file, 'utf8'), errors = [];
  const data = parse(text, errors, { allowTrailingComma: true });
  if (errors.length || typeof data !== 'object' || data === null || Array.isArray(data))
    throw new Error(`${file} could not be read (${errors.length ? printParseErrorCode(errors[0].error) : 'not an object'}). Fix it or add Open Computer Use by hand: ocu setup --print`);
  return { text, data };
}
async function editSettings(file, path, value, initial = '{}\n') {
  const target = await exists(file) ? await realpath(file) : file;
  const { text } = await readSettings(target);
  const next = applyEdits(text ?? initial, modify(text ?? initial, path, value, FORMAT));
  if (next === text) return;
  await mkdir(dirname(target), { recursive: true });
  const mode = text === null ? 0o644 : (await stat(target)).mode & 0o777;
  if (text !== null) await copyFile(target, `${target}.ocu-backup`);
  const temporary = `${target}.ocu-${process.pid}`;
  await writeFile(temporary, next, { mode });
  await rename(temporary, target);
}
const commandOf = entry => entry ? [entry.command ?? entry.transport?.command, ...(entry.args ?? entry.transport?.args ?? [])].flat().filter(v => v !== undefined) : null;

const claudeFile = ctx => ctx.env.CLAUDE_CONFIG_DIR ? join(ctx.env.CLAUDE_CONFIG_DIR, '.claude.json') : join(ctx.home, '.claude.json');
const cursorFile = ctx => join(ctx.home, '.cursor/mcp.json');
async function opencodeFile(ctx) {
  const dir = join(ctx.env.XDG_CONFIG_HOME || join(ctx.home, '.config'), 'opencode');
  for (const name of ['opencode.json', 'opencode.jsonc']) if (await exists(join(dir, name))) return join(dir, name);
  return join(dir, 'opencode.json');
}
async function cli(ctx, bin, args) {
  const result = await ctx.run(bin, args);
  if (result.code !== 0) throw new Error((result.stderr || result.stdout).trim() || `${basename(bin)} exited ${result.code}`);
  return result.stdout;
}

/** Each agent: how to find it, read its current entry, and add or remove ours. */
export const AGENTS = {
  claude: {
    name: 'Claude Code',
    find: ctx => which(ctx, 'claude'),
    // Read from the user settings; written through Claude's own command.
    read: async ctx => commandOf((await readSettings(claudeFile(ctx))).data.mcpServers?.[SERVER]),
    add: async (ctx, bin, ocu) => cli(ctx, bin, ['mcp', 'add', '--scope', 'user', SERVER, '--', ocu, 'mcp']),
    remove: async (ctx, bin) => cli(ctx, bin, ['mcp', 'remove', '--scope', 'user', SERVER]),
    snippet: ocu => `claude mcp add --scope user ${SERVER} -- ${quote(ocu)} mcp`,
  },
  codex: {
    name: 'Codex',
    find: ctx => which(ctx, 'codex'),
    read: async (ctx, bin) => {
      const result = await ctx.run(bin, ['mcp', 'get', SERVER, '--json']);
      if (result.code !== 0) return null;
      try { return commandOf(JSON.parse(result.stdout)); } catch { return null; }
    },
    add: async (ctx, bin, ocu) => cli(ctx, bin, ['mcp', 'add', SERVER, '--', ocu, 'mcp']),
    remove: async (ctx, bin) => cli(ctx, bin, ['mcp', 'remove', SERVER]),
    snippet: ocu => `# ~/.codex/config.toml\n[mcp_servers.${SERVER}]\ncommand = ${JSON.stringify(ocu)}\nargs = ["mcp"]`,
  },
  cursor: {
    name: 'Cursor',
    // The editor and its CLI share ~/.cursor/mcp.json.
    find: async ctx => ((await Promise.all(ctx.applications.map(dir => exists(join(dir, 'Cursor.app'))))).includes(true)
      || await which(ctx, 'cursor-agent') || await exists(join(ctx.home, '.cursor'))) ? cursorFile(ctx) : null,
    read: async ctx => commandOf((await readSettings(cursorFile(ctx))).data.mcpServers?.[SERVER]),
    add: (ctx, _, ocu) => editSettings(cursorFile(ctx), ['mcpServers', SERVER], { type: 'stdio', command: ocu, args: ['mcp'] }),
    remove: ctx => editSettings(cursorFile(ctx), ['mcpServers', SERVER], undefined),
    snippet: ocu => `// ~/.cursor/mcp.json\n${JSON.stringify({ mcpServers: { [SERVER]: { type: 'stdio', command: ocu, args: ['mcp'] } } }, null, 2)}`,
  },
  opencode: {
    name: 'OpenCode',
    find: async ctx => (await which(ctx, 'opencode') || await exists(dirname(await opencodeFile(ctx)))) ? opencodeFile(ctx) : null,
    read: async ctx => (await readSettings(await opencodeFile(ctx))).data.mcp?.[SERVER]?.command ?? null,
    add: async (ctx, _, ocu) => editSettings(await opencodeFile(ctx), ['mcp', SERVER], { type: 'local', command: [ocu, 'mcp'], enabled: true },
      '{\n  "$schema": "https://opencode.ai/config.json"\n}\n'),
    remove: async ctx => editSettings(await opencodeFile(ctx), ['mcp', SERVER], undefined),
    snippet: ocu => `// ~/.config/opencode/opencode.json\n${JSON.stringify({ mcp: { [SERVER]: { type: 'local', command: [ocu, 'mcp'], enabled: true } } }, null, 2)}`,
  },
};

const sameCommand = (command, ocu) => Array.isArray(command) && command.length === 2 && command[0] === ocu && command[1] === 'mcp';

/**
 * One agent's state: not_installed, available (installed, not connected),
 * connected (launches this ocu) or outdated (launches another ocu, for example
 * an older copy of the app or one that has moved).
 */
export async function agentStatus(ctx, id, ocu) {
  const agent = AGENTS[id];
  const bin = await agent.find(ctx);
  if (!bin) return { id, name: agent.name, status: 'not_installed' };
  let command;
  try { command = await agent.read(ctx, bin); }
  catch (error) { return { id, name: agent.name, status: 'error', message: error.message }; }
  const status = !command ? 'available' : sameCommand(command, ocu) ? 'connected' : 'outdated';
  return { id, name: agent.name, status, ...(command ? { command } : {}) };
}
export const statusAll = (ctx, ocu) => Promise.all(Object.keys(AGENTS).map(id => agentStatus(ctx, id, ocu)));

export async function connect(ctx, id, ocu) {
  const agent = AGENTS[id], bin = await agent.find(ctx);
  if (!bin) throw new Error(`${agent.name} was not found on this Mac.`);
  const command = await agent.read(ctx, bin);
  if (sameCommand(command, ocu)) return agentStatus(ctx, id, ocu);
  // Replacing an outdated entry: the agents' own add commands refuse to overwrite.
  if (command) await agent.remove(ctx, bin);
  await agent.add(ctx, bin, ocu);
  return agentStatus(ctx, id, ocu);
}
export async function disconnect(ctx, id, ocu) {
  const agent = AGENTS[id], bin = await agent.find(ctx);
  if (bin && await agent.read(ctx, bin)) await agent.remove(ctx, bin);
  return agentStatus(ctx, id, ocu);
}

/** Settings to add by hand, for one agent or any other MCP client. */
export function snippet(id, ocu) {
  if (id) return AGENTS[id].snippet(ocu);
  return `Any MCP client: a stdio server named ${SERVER} that runs\n${JSON.stringify({ command: ocu, args: ['mcp'] }, null, 2)}`;
}

const LABEL = { connected: 'Connected', outdated: 'Needs update (points to another copy of Open Computer Use)', available: 'Not connected', not_installed: 'Not installed', error: 'Problem' };

/** `ocu setup [AGENT] [--remove] [--print] [--json]` */
export async function runSetup(args, { ctx = context(), execPath, input = process.stdin, output = process.stdout } = {}) {
  const json = args.includes('--json'), remove = args.includes('--remove'), print = args.includes('--print');
  const [id, ...extra] = args.filter(arg => !arg.startsWith('--'));
  const unknown = args.find(arg => arg.startsWith('--') && !['--json', '--remove', '--print'].includes(arg));
  const write = text => output.write(`${text}\n`);
  if (unknown || extra.length || (id && !AGENTS[id]) || (remove && !id)) {
    write(`Usage: ocu setup [${Object.keys(AGENTS).join(' | ')}] [--remove] [--print] [--json]`);
    return 1;
  }
  const ocu = ctx.ocu ?? await ocuPath(execPath);
  if (print) { write(snippet(id, ocu)); return 0; }
  if (id) {
    const result = remove ? await disconnect(ctx, id, ocu) : await connect(ctx, id, ocu);
    if (json) write(JSON.stringify(result, null, 2));
    else write(remove ? `Disconnected ${result.name}.` : `Connected ${result.name}. Restart it, or start a new session, to use Open Computer Use.`);
    return 0;
  }
  const agents = await statusAll(ctx, ocu);
  if (json) { write(JSON.stringify({ server: SERVER, command: [ocu, 'mcp'], agents }, null, 2)); return 0; }
  for (const agent of agents) write(`${agent.name.padEnd(12)} ${LABEL[agent.status]}${agent.message ? `: ${agent.message}` : ''}`);
  const pending = agents.filter(agent => ['available', 'outdated'].includes(agent.status));
  if (!pending.length) { write(agents.some(a => a.status === 'connected') ? '' : '\nNo supported agent found. Other MCP clients: ocu setup --print'); return 0; }
  if (!input.isTTY) { write(`\nConnect one with: ocu setup ${pending[0].id}`); return 0; }
  const { createInterface } = await import('node:readline/promises');
  const prompt = createInterface({ input, output });
  try {
    for (const agent of pending) {
      const answer = (await prompt.question(`Connect ${agent.name}? [Y/n] `)).trim().toLowerCase();
      if (answer && answer !== 'y' && answer !== 'yes') continue;
      await connect(ctx, agent.id, ocu);
      write(`Connected ${agent.name}. Restart it, or start a new session, to use Open Computer Use.`);
    }
  } finally { prompt.close(); }
  return 0;
}
