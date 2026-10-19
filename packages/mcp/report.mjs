import { execFileSync } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { appendFile, mkdir } from 'node:fs/promises';
import { homedir, userInfo } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import pkg from '../../package.json' with { type: 'json' };
import { failure, runtimeDirectory } from '../protocol/index.mjs';
// report_issue saves a report on this Mac and returns a prefilled link to the
// public bug form. Nothing leaves the machine unless a person submits the form.
export const ISSUE_FORM = 'https://github.com/andrewslabmd/opencomputeruse/issues/new';
export const REPORTS_FILE = 'issue-reports.jsonl';
const SEVERITIES = ['blocker', 'major', 'minor'];
const text = description => ({ type: 'string', minLength: 1, maxLength: 2000, description });
export const reportIssueTool = {
  name: 'report_issue',
  description: 'Report a problem with Open Computer Use itself to its maintainers. Call this once when one of these tools did not behave as documented and you had to work around it (or could not), then continue the user\'s task. Describe the tool behavior in general terms: no application content, document text, names, accounts, file paths or other personal data. Nothing is sent: the report is saved on this Mac and you get a prefilled link to the public GitHub bug form. Give the link to the user, who checks it and decides whether to submit it. Version, macOS, Mac model, your client name and the names of your recent Open Computer Use calls are added automatically.',
  inputSchema: {
    type: 'object',
    additionalProperties: false,
    properties: {
      summary: { type: 'string', minLength: 1, maxLength: 120, description: 'One-line title, for example "type with replace=true leaves the old text in a search field".' },
      expected: text('What the documentation or tool description says should have happened.'),
      what_happened: text('What happened instead, including the status or error code returned.'),
      workaround: { ...text('What you did instead to continue, if anything.'), minLength: 0 },
      severity: { type: 'string', enum: SEVERITIES, description: 'blocker: the task could not be completed; major: it needed a workaround; minor: cosmetic, or a misleading description or result.' },
    },
    required: ['summary', 'expected', 'what_happened', 'severity'],
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
// Best effort only: the user still reviews the link before submitting.
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
export function issueUrl(report, options) {
  const r = s => redact(s, options);
  const what = [`Expected: ${r(report.expected)}`, `What happened: ${r(report.what_happened)}`, report.workaround ? `Workaround: ${r(report.workaround)}` : '', `Severity: ${report.severity}`].filter(Boolean).join('\n\n');
  const calls = report.recent_calls.length ? report.recent_calls.map((c, i) => `${i + 1}. ${c.tool}${c.actions ? ` [${c.actions.join(', ')}]` : ''}: ${c.outcome}`).join('\n') : '(none)';
  const reproduce = `Reported by an agent through report_issue. Its last Open Computer Use calls (names only):\n${calls}\n\nIf you can, add steps that reproduce it with a public app (TextEdit, Finder, Calculator).`;
  const params = new URLSearchParams({
    template: 'bug_report.yml', title: clip(r(report.summary), 120),
    what: clip(what, 3000), reproduce: clip(reproduce, 1500),
    version: `${report.version} (${report.commit})`,
    environment: `macOS ${report.macos}, ${report.mac_model} (${report.chip}), ${r(report.client.name)} ${r(report.client.version)}`.trim(),
    logs: `Local report ${report.id}`,
  });
  return `${ISSUE_FORM}?${params}`;
}
export async function reportIssue(args = {}, { client = {}, recent = new RecentCalls(), directory = runtimeDirectory(), env = environment(), redaction } = {}) {
  for (const key of ['summary', 'expected', 'what_happened']) if (typeof args[key] !== 'string' || !args[key].trim()) throw failure('invalid_arguments', `${key} is required`);
  if (!SEVERITIES.includes(args.severity)) throw failure('invalid_arguments', `severity must be one of ${SEVERITIES.join(', ')}`);
  if (args.workaround !== undefined && typeof args.workaround !== 'string') throw failure('invalid_arguments', 'workaround must be a string');
  const report = {
    id: randomBytes(4).toString('hex'), created_at: new Date().toISOString(),
    summary: args.summary.trim().slice(0, 120), expected: args.expected.slice(0, 2000), what_happened: args.what_happened.slice(0, 2000), workaround: (args.workaround || '').slice(0, 2000), severity: args.severity,
    ...env, client: { name: client.name || 'unknown', version: client.version || '' }, recent_calls: recent.items.map(c => ({ ...c })),
  };
  report.issue_url = issueUrl(report, redaction);
  await mkdir(directory, { recursive: true, mode: 0o700 });
  await appendFile(join(directory, REPORTS_FILE), JSON.stringify(report) + '\n', { mode: 0o600 });
  return report;
}
export function reportResult(report, { repeated = false, directory = runtimeDirectory() } = {}) {
  return {
    status: repeated ? 'already_reported' : 'saved', report_id: report.id, saved_to: join(directory, REPORTS_FILE).replace(homedir(), '~'),
    issue_url: report.issue_url,
    next: 'Nothing was sent. Give the user this link: it opens the public Open Computer Use bug form, filled in. Ask them to check it contains nothing personal before submitting. Then continue the task.',
  };
}
