import { execFileSync } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { appendFile, mkdir, readFile } from 'node:fs/promises';
import { homedir, userInfo } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import pkg from '../../package.json' with { type: 'json' };
import { failure, runtimeDirectory } from '../protocol/index.mjs';
// Saving stays local. Only an explicit share:true sends a saved report.
const REPORT_ENDPOINT = 'https://inbox-intake.medhuelabs-opencode.workers.dev/report';
export const REPORTS_FILE = 'issue-reports.jsonl';
const SEVERITIES = ['blocker', 'major', 'minor'];
const text = description => ({ type: 'string', minLength: 1, maxLength: 2000, description });
export const reportIssueTool = {
  name: 'report_issue',
  description: 'Report a problem with Open Computer Use itself, whether you or the user noticed it. Call once per problem with summary, expected, what_happened, severity and optional workaround (report_id and share stay out of this first call). Describe tool behavior only: no application content, document text, names, accounts, file paths or other personal data. This saves locally and returns ask_user with a preview. Ask the user once whether to share it with the Open Computer Use developers; it contains the summary, versions and recent tool call names, nothing from their apps or files. Only on yes call this tool with {report_id, share:true} to send it to the maintainers\' private inbox. On no, do not ask again. Then continue the user\'s task.',
  inputSchema: {
    type: 'object',
    additionalProperties: false,
    properties: {
      summary: { type: 'string', minLength: 1, maxLength: 120, description: 'One-line title, for example "type with replace=true leaves the old text in a search field".' },
      expected: text('What the documentation or tool description says should have happened.'),
      what_happened: text('What happened instead, including the status or error code returned.'),
      workaround: { ...text('What you did instead to continue, if anything.'), minLength: 0 },
      severity: { type: 'string', enum: SEVERITIES, description: 'blocker: the task could not be completed; major: it needed a workaround; minor: cosmetic, or a misleading description or result.' },
      report_id: { type: 'string', minLength: 1, description: 'The saved report ID returned by this tool.' },
      share: { type: 'boolean', description: 'true sends the saved report; only after the user says yes.' },
    },
    // Two call shapes, checked in reportIssue: no top-level oneOf, which some
    // clients (including the Claude API) reject in tool schemas.
  },
};
// Names of the agent's recent calls through this adapter, never their content.
export class RecentCalls {
  constructor(limit = 8) { this.limit = limit; this.items = []; }
  record(name, args, outcome) {
    const entry = { tool: name, outcome };
    if (name === 'computer_use_action_batch' && Array.isArray(args?.actions)) entry.actions = args.actions.map(a => (typeof a?.kind === 'string' && /^[a-z_]{1,32}$/.test(a.kind) ? a.kind : 'invalid'));
    this.items.push(entry); if (this.items.length > this.limit) this.items.shift();
  }
}
// Outcome labels are our own error codes, never result text.
export const outcomeOf = (result, error) => error ? (/^[a-z_]{1,40}$/.test(error.code || '') ? error.code : 'error') : result?.isError ? 'error' : 'ok';
const run = (cmd, args) => { try { return execFileSync(cmd, args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], timeout: 2_000 }).trim(); } catch { return ''; } };
// Release builds define OCU_BUILD_COMMIT (scripts/build.mjs); source runs ask Git.
const commit = () => process.env.OCU_BUILD_COMMIT || run('git', ['-C', fileURLToPath(new URL('../..', import.meta.url)), 'rev-parse', '--short', 'HEAD']) || 'unknown';
export function environment() {
  return { version: pkg.version, commit: commit(), macos: run('sw_vers', ['-productVersion']) || 'unknown', mac_model: run('sysctl', ['-n', 'hw.model']) || 'unknown', chip: run('sysctl', ['-n', 'machdep.cpu.brand_string']) || process.arch };
}
const escape = s => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
// Best effort only; agents must leave out application content and personal data.
export function redact(value, { home = homedir(), user = userInfo().username } = {}) {
  let out = String(value);
  if (home && home.length > 1) out = out.split(home).join('~');
  out = out.replace(/\/Users\/[^/\s]+/g, '~');
  out = out.replace(/[\w.+-]+@[\w-]+(\.[\w-]+)+/g, '[email]');
  out = out.replace(/(https?:\/\/[^\s?#]+)[?#]\S*/g, '$1?[removed]');
  if (user && user.length >= 3) out = out.replace(new RegExp(`\\b${escape(user)}\\b`, 'gi'), '[user]');
  return out;
}
const clip = (s, n) => s.length > n ? s.slice(0, n - 1) + '…' : s;
export function reportPayload(report, options) {
  // Match intake's control-character cleaning before applying its size limits.
  const r = s => redact(s, options).replace(/\r\n?/g, '\n').replace(/[\u0000-\u0009\u000b-\u001f\u007f-\u009f]/g, '').trim();
  const field = (s, n) => clip(r(s).replace(/\n/g, ' '), n);
  const calls = report.recent_calls.length ? report.recent_calls.map((c, i) => `${i + 1}. ${c.tool}${c.actions ? ` [${c.actions.join(', ')}]` : ''}: ${c.outcome}`).join('\n') : '(none)';
  // Bound each section so long descriptions cannot crowd out the call names.
  const message = [clip(r(report.summary), 120), `Expected: ${clip(r(report.expected), 1200)}`, `What happened: ${clip(r(report.what_happened), 1200)}`, report.workaround ? `Workaround: ${clip(r(report.workaround), 1200)}` : '', `Severity: ${report.severity}`, `Recent tool calls (names, action kinds and outcomes only):\n${r(calls)}`].filter(Boolean).join('\n\n');
  return {
    product: 'opencomputeruse', source: 'agent', via: 'mcp', message: clip(message, 5000),
    version: field(`${report.version} (${report.commit})`, 100),
    platform: `macOS ${field(report.macos, 10)}, ${field(report.mac_model, 16)} (${field(report.chip, 20)}), ${field(report.client.name, 20)} ${field(report.client.version, 18)}`.trim(),
  };
}
export async function reportIssue(args = {}, { client = {}, recent = new RecentCalls(), directory = runtimeDirectory(), env = environment(), redaction } = {}) {
  if (args.share !== undefined || args.report_id !== undefined) {
    if (args.share !== true || typeof args.report_id !== 'string' || !args.report_id.trim() || Object.keys(args).some(key => !['report_id', 'share'].includes(key))) throw failure('invalid_arguments', 'Sharing requires only report_id and share: true');
    return shareReport(args.report_id, { directory, redaction });
  }
  for (const key of ['summary', 'expected', 'what_happened']) if (typeof args[key] !== 'string' || !args[key].trim()) throw failure('invalid_arguments', `${key} is required`);
  if (!SEVERITIES.includes(args.severity)) throw failure('invalid_arguments', `severity must be one of ${SEVERITIES.join(', ')}`);
  if (args.workaround !== undefined && typeof args.workaround !== 'string') throw failure('invalid_arguments', 'workaround must be a string');
  const report = {
    id: randomBytes(4).toString('hex'), created_at: new Date().toISOString(),
    summary: args.summary.trim().slice(0, 120), expected: args.expected.slice(0, 2000), what_happened: args.what_happened.slice(0, 2000), workaround: (args.workaround || '').slice(0, 2000), severity: args.severity,
    ...env, client: { name: client.name || 'unknown', version: client.version || '' }, recent_calls: recent.items.map(c => ({ ...c })),
  };
  // Redact the local copy too, so preview and later sending use the same text.
  for (const key of ['summary', 'expected', 'what_happened', 'workaround', 'version', 'commit', 'macos', 'mac_model', 'chip']) report[key] = redact(report[key], redaction);
  report.client = { name: redact(report.client.name, redaction), version: redact(report.client.version, redaction) };
  await mkdir(directory, { recursive: true, mode: 0o700 });
  await appendFile(join(directory, REPORTS_FILE), JSON.stringify(report) + '\n', { mode: 0o600 });
  return report;
}
export function reportResult(report, { repeated = false, directory = runtimeDirectory() } = {}) {
  const payload = reportPayload(report);
  return {
    status: repeated ? 'already_reported' : 'ask_user', report_id: report.id, saved_to: join(directory, REPORTS_FILE).replace(homedir(), '~'),
    preview: `Product: ${payload.product}\nSource: ${payload.source}\nVia: ${payload.via}\n\n${payload.message}\n\nVersion: ${payload.version}\nPlatform: ${payload.platform}`,
    next: repeated ? 'This problem was already reported. Do not ask again; continue the task.' : `Nothing was sent. Ask the user once, in plain words: "Share this bug report with the Open Computer Use developers? It contains the summary, versions and names of recent tool calls, and nothing from your apps or files." This applies even when the user flagged the bug. On yes, call report_issue with {"report_id":"${report.id}","share":true}. On no, do not ask again. Continue the task.`,
  };
}

async function shareReport(id, { directory, redaction }) {
  let lines;
  try { lines = (await readFile(join(directory, REPORTS_FILE), 'utf8')).trim().split('\n').filter(Boolean).map(line => JSON.parse(line)); }
  catch (error) { if (error.code !== 'ENOENT') throw error; lines = []; }
  const report = lines.find(line => line.id === id && line.summary);
  if (!report) throw failure('invalid_arguments', 'Unknown report_id');
  if (lines.some(line => line.id === id && line.shared_at)) return { status: 'already_sent', report_id: id };
  try {
    const response = await fetch(process.env.OCU_REPORT_ENDPOINT || REPORT_ENDPOINT, {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(reportPayload(report, redaction)), signal: AbortSignal.timeout(5_000), redirect: 'error',
    });
    await response.body?.cancel();
    if (!response.ok) return { status: 'send_failed', report_id: id, reason: `Intake returned HTTP ${response.status}; the local report is kept.` };
  } catch (error) {
    return { status: 'send_failed', report_id: id, reason: error.name === 'TimeoutError' ? 'Intake timed out; the local report is kept.' : 'Could not reach intake; the local report is kept.' };
  }
  await appendFile(join(directory, REPORTS_FILE), JSON.stringify({ id, shared_at: new Date().toISOString() }) + '\n', { mode: 0o600 });
  return { status: 'sent', report_id: id };
}
