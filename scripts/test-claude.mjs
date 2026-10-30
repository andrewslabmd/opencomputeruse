import { spawn, spawnSync } from 'node:child_process';
import { mkdir, writeFile, readFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import assert from 'node:assert/strict';
import { assertFixtureFocus, waitForFixtureState } from './live-support/fixture-focus.mjs';
if (!process.argv.includes('--interactive')) throw new Error('Native Claude test requires explicit --interactive authorization');
await mkdir('work', { recursive: true });
const build = spawnSync('xcrun', ['swiftc', '-parse-as-library', 'tests/native-fixtures/ComputerUseFixture.swift', '-o', 'work/ComputerUseFixture'], { stdio: 'inherit' });
if (build.status) process.exit(build.status);
const resultPath = resolve(`work/claude-fixture-${Date.now()}.json`);
const fixture = spawn(resolve('work/ComputerUseFixture'), [resultPath], { stdio: 'ignore' });
try {
  await waitForFixtureState(resultPath, s => s.ready && !s.appActive);
  const config = resolve('work/claude-test-mcp.json');
  await writeFile(config, JSON.stringify({ mcpServers: { opencomputeruse: { command: resolve('dist/Open Computer Use.app/Contents/MacOS/ocu'), args: ['mcp'] } } }));
  const prompt = `Operate ONLY synthetic application PID:${fixture.pid} (ComputerUseFixture). Observe it. Click Begin Test, replace Fixture Input with exactly Standalone Claude acceptance, click Panel Action in its transient panel, then click Commit. Use observed coordinates and one batch if all controls are visible. The user explicitly authorized this synthetic test. Do not operate any other app. Release your workflow after finishing and report the result.`;
  const operator = await readFile('integrations/claude-code/operator.md', 'utf8');
  const output = await new Promise((res, rej) => {
    const child = spawn('claude', ['-p', prompt, '--append-system-prompt', operator, '--setting-sources', '', '--mcp-config', config, '--strict-mcp-config', '--tools', 'Read,Bash', '--allowedTools', 'Read', 'Bash', 'mcp__opencomputeruse__computer_use_observe', 'mcp__opencomputeruse__computer_use_permissions', 'mcp__opencomputeruse__computer_use_status', 'mcp__opencomputeruse__computer_use_action_batch', 'mcp__opencomputeruse__computer_use_release', '--no-session-persistence', '--output-format', 'json'], { env: { ...process.env, ENABLE_TOOL_SEARCH: 'false', MCP_TIMEOUT: '15000' }, stdio: ['ignore', 'pipe', 'pipe'] });
    let stdout = ''; let stderr = '';
    const timer = setTimeout(() => child.kill('SIGTERM'), 120000);
    child.stdout.on('data', d => { stdout += d; }); child.stderr.on('data', d => { stderr += d; });
    child.once('error', e => { clearTimeout(timer); rej(e); }); child.once('exit', code => { clearTimeout(timer); code === 0 ? res(stdout) : rej(new Error(`Claude failed (${code}): ${stderr.slice(-1000)}`)); });
  });
  const response = JSON.parse(output);
  await writeFile('work/claude-acceptance-response.json', JSON.stringify({ is_error: response.is_error, num_turns: response.num_turns, result: response.result }, null, 2));
  const native = await waitForFixtureState(resultPath, s => s.committed && !s.appActive);
  assert.equal(native.text, 'Standalone Claude acceptance'); assert.equal(native.panelActionPerformed, true);
  assertFixtureFocus(native, { active: false, pid: fixture.pid });
  const evidence = { passed: true, client: 'Claude Code', native, turns: response.num_turns };
  await writeFile('work/claude-acceptance.json', JSON.stringify(evidence, null, 2)); console.log(JSON.stringify(evidence, null, 2));
} finally { fixture.kill('SIGTERM'); }
