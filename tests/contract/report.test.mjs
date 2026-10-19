import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import Ajv from 'ajv';
import { Host } from '../../packages/host/server.mjs';
import { Broker } from '../../packages/host/broker.mjs';
import { RecentCalls, reportIssue, reportPayload, reportIssueTool, redact, REPORTS_FILE } from '../../packages/mcp/report.mjs';
const issue = { summary: 'type with replace=true kept the old text', expected: 'The field holds only the new text.', what_happened: 'The new text was appended; status ok.', workaround: 'Selected all with a hotkey first.', severity: 'major' };
const reports = async directory => (await readFile(join(directory, REPORTS_FILE), 'utf8')).trim().split('\n').map(line => JSON.parse(line));
const call = async (client, args) => JSON.parse((await client.call('report_issue', args)).content[0].text);
async function fixture(t) {
  const directory = await mkdtemp(join(tmpdir(), 'ocu-report-'));
  const intake = { requests: [], status: 202 };
  const server = createServer(async (req, res) => {
    let raw = ''; for await (const chunk of req) raw += chunk;
    intake.requests.push({ method: req.method, url: req.url, type: req.headers['content-type'], body: JSON.parse(raw) });
    res.writeHead(intake.status, { 'Content-Type': 'application/json' }); res.end(JSON.stringify(intake.status === 202 ? { ok: true } : { error: 'private upstream details' }));
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const client = new Broker(process.execPath, ['packages/cli/main.mjs', 'mcp'], { ...process.env, OCU_RUNTIME_DIR: directory, OCU_REPORT_ENDPOINT: `http://127.0.0.1:${server.address().port}/report` });
  const cleanup = [() => client.stop()];
  t.after(async () => { for (const dispose of cleanup) await dispose(); server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); await rm(directory, { recursive: true, force: true }); });
  return { directory, client, intake, cleanup };
}
test('report_issue asks once, then sends only the preview with names of recent calls', async t => {
  const { directory, client, intake, cleanup } = await fixture(t);
  const backend = { async call() { return { content: [{ type: 'text', text: 'private document text' }] }; }, async stop() {}, async reset() {} };
  const host = new Host({ directory, broker: backend }); await host.start();
  cleanup.push(() => host.close());
  const tool = (await client.list()).tools.find(t => t.name === 'report_issue');
  assert.match(tool.description, /once/); assert.match(tool.description, /continue/); assert.match(tool.description, /Only on yes/);
  await client.call('computer_use_observe', { app_target: 'Secret Notes' });
  await client.call('computer_use_action_batch', { actions: [{ kind: 'type', at: { x: 1, y: 1 }, text: 'my secret words' }, { kind: 'hotkey', keys: ['cmd', 'a'] }] });
  const result = await call(client, { ...issue, what_happened: 'Failed for jane@example.com in /Users/jdoe at https://app.example.com/doc?token=abc' });
  assert.equal(result.status, 'ask_user'); assert.match(result.next, /Nothing was sent/); assert.match(result.next, /Ask the user once/); assert.match(result.next, /On no, do not ask again/);
  assert.equal(intake.requests.length, 0);
  const [saved] = await reports(directory);
  assert.equal(saved.id, result.report_id); assert.equal(saved.client.name, 'opencomputeruse-host'); assert.ok(saved.version && saved.commit && saved.macos && saved.mac_model);
  assert.deepEqual(saved.recent_calls, [{ tool: 'computer_use_observe', outcome: 'ok' }, { tool: 'computer_use_action_batch', outcome: 'observation_required', actions: ['type', 'hotkey'] }]);
  const repeated = await call(client, { ...issue, summary: `  ${issue.summary.toUpperCase()}  ` });
  assert.equal(repeated.status, 'already_reported'); assert.equal(repeated.report_id, saved.id); assert.match(repeated.next, /Do not ask again/);
  assert.equal((await reports(directory)).length, 1); assert.equal(intake.requests.length, 0);
  // Even overlapping shares must not dispatch two requests.
  const share = { report_id: saved.id, share: true };
  assert.deepEqual((await Promise.all([call(client, share), call(client, share)])).map(r => r.status), ['sent', 'already_sent']);
  assert.equal(intake.requests.length, 1);
  const request = intake.requests[0]; const body = request.body;
  assert.equal(request.method, 'POST'); assert.equal(request.url, '/report'); assert.equal(request.type, 'application/json');
  assert.deepEqual(Object.keys(body).sort(), ['product', 'source', 'via', 'message', 'version', 'platform'].sort());
  assert.equal(body.product, 'opencomputeruse'); assert.equal(body.source, 'agent'); assert.equal(body.via, 'mcp');
  assert.ok(body.message.startsWith(`${issue.summary}\n\nExpected:`));
  assert.match(body.message, /What happened: Failed for \[email\] in ~ at https:\/\/app.example.com\/doc\?\[removed\]/);
  assert.match(body.message, /Workaround: Selected all/); assert.match(body.message, /Severity: major/);
  assert.match(body.message, /computer_use_action_batch \[type, hotkey\]: observation_required/);
  assert.equal(body.version, `${saved.version} (${saved.commit})`); assert.match(body.platform, /macOS .*opencomputeruse-host 0.1.0/);
  assert.ok(body.message.length <= 5000 && body.platform.length <= 100 && body.version.length <= 100);
  assert.equal(result.preview, `Product: ${body.product}\nSource: ${body.source}\nVia: ${body.via}\n\n${body.message}\n\nVersion: ${body.version}\nPlatform: ${body.platform}`);
  for (const content of ['Secret Notes', 'my secret words', 'private document text', 'jane@example.com', '/Users/jdoe', 'token=abc', 'issue_url']) {
    assert.ok(!JSON.stringify({ saved, result, body }).includes(content), content);
  }
  const updates = await reports(directory); assert.equal(updates.length, 2); assert.equal(updates[1].id, saved.id); assert.ok(Date.parse(updates[1].shared_at));
  // Persisted shared_at also prevents sending from a fresh adapter session.
  const restarted = new Broker(client.command, client.args, client.env); cleanup.unshift(() => restarted.stop());
  assert.equal((await call(restarted, share)).status, 'already_sent'); assert.equal(intake.requests.length, 1);
});
test('report_issue works without a host; unknown IDs and missing consent are errors', async t => {
  const { directory, client, intake } = await fixture(t);
  const unknown = await client.call('report_issue', { report_id: 'unknown', share: true });
  assert.equal(unknown.isError, true); assert.match(unknown.content[0].text, /Unknown report_id/);
  const result = await call(client, { ...issue, workaround: undefined, severity: 'blocker' });
  assert.equal(result.status, 'ask_user');
  const [saved] = await reports(directory); assert.deepEqual(saved.recent_calls, []); assert.ok(!result.preview.includes('Workaround:'));
  for (const args of [{ report_id: saved.id }, { report_id: saved.id, share: false }, { ...issue, report_id: saved.id, share: true }, { share: true }]) {
    const invalid = await client.call('report_issue', args); assert.equal(invalid.isError, true); assert.match(invalid.content[0].text, /Sharing requires/);
  }
  const invalid = await client.call('report_issue', { summary: 'x', severity: 'major' });
  assert.equal(invalid.isError, true); assert.match(invalid.content[0].text, /expected is required/);
  assert.equal(intake.requests.length, 0);
  assert.equal((await call(client, { report_id: saved.id, share: true })).status, 'sent');
});
test('a Worker failure returns send_failed, keeps the report and permits a retry', async t => {
  const { directory, client, intake } = await fixture(t);
  const saved = await call(client, issue); const before = await readFile(join(directory, REPORTS_FILE), 'utf8');
  intake.status = 502;
  const share = { report_id: saved.report_id, share: true }; const failed = await call(client, share);
  assert.equal(failed.status, 'send_failed'); assert.match(failed.reason, /HTTP 502/); assert.ok(!failed.reason.includes('private upstream details'));
  assert.equal(await readFile(join(directory, REPORTS_FILE), 'utf8'), before);
  assert.equal(intake.requests.length, 1);
  intake.status = 202;
  assert.equal((await call(client, share)).status, 'sent'); assert.equal(intake.requests.length, 2);
  assert.equal((await call(client, share)).status, 'already_sent'); assert.equal(intake.requests.length, 2);
});
test('schema works in clients that reject top-level combinators; mixed calls are refused', async t => {
  const schema = reportIssueTool.inputSchema;
  for (const key of ['oneOf', 'anyOf', 'allOf', 'not']) assert.equal(schema[key], undefined, key);
  const validate = new Ajv({ strict: false }).compile(schema);
  assert.equal(validate(issue), true); assert.equal(validate({ report_id: 'abcd1234', share: true }), true); assert.equal(validate({ ...issue, unknown: 'x' }), false);
  const directory = await mkdtemp(join(tmpdir(), 'ocu-report-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  for (const args of [{ report_id: 'abcd1234' }, { report_id: 'abcd1234', share: false }, { ...issue, report_id: 'abcd1234', share: true }]) {
    await assert.rejects(reportIssue(args, { directory }), { code: 'invalid_arguments' });
  }
});
test('payload redacts text and bounds intake fields', () => {
  const options = { home: '/Users/jdoe', user: 'jdoe' };
  assert.equal(redact('Opened /Users/jdoe/Documents/plan.txt for jdoe (jane@example.com) at https://app.example.com/doc?token=abc', options), 'Opened ~/Documents/plan.txt for [user] ([email]) at https://app.example.com/doc?[removed]');
  const recent = new RecentCalls(2);
  for (const kind of ['click', 'type', 'Bad Kind!']) recent.record('computer_use_action_batch', { actions: [{ kind }] }, 'ok');
  assert.deepEqual(recent.items.map(c => c.actions), [['type'], ['invalid']]);
  const report = { ...issue, summary: 'Fails in /Users/jdoe/x', what_happened: 'mail jane@example.com', version: '0.1.0', commit: 'abc1234', macos: '26.0', mac_model: 'Mac15,8', chip: 'Apple M3', client: { name: 'claude-code', version: '2.1.0' }, recent_calls: recent.items };
  const payload = reportPayload(report, options);
  assert.ok(payload.message.startsWith('Fails in ~/x\n\n')); assert.match(payload.message, /mail \[email\]/);
  assert.equal(payload.platform, 'macOS 26.0, Mac15,8 (Apple M3), claude-code 2.1.0');
  const bounded = reportPayload({ ...report, expected: '界'.repeat(2000), what_happened: '界'.repeat(2000), workaround: '界'.repeat(2000), client: { name: 'x'.repeat(60), version: 'v'.repeat(40) } });
  assert.ok(bounded.message.length <= 5000); assert.ok(bounded.platform.length <= 100); assert.ok(Buffer.byteLength(JSON.stringify(bounded)) <= 16384);
  assert.match(bounded.message, /Severity: major/); assert.match(bounded.message, /Recent tool calls/);
});
