import { spawn } from 'node:child_process';
import { frameReader, failure } from '../protocol/index.mjs';
import { requestComputerUseHelper } from '../engine/computer-use-helper-client.mjs';

// One private engine per agent workflow; the host keeps workflows to separate apps.
export class Broker {
  constructor(command, args = [], env = process.env) { this.command = command; this.args = args; this.env = env; this.next = 0; this.pending = new Map(); }
  async start() {
    if (this.ready) return this.ready;
    this.ready = this.boot().catch(error => { this.ready = null; throw error; });
    return this.ready;
  }
  async boot() {
    this.child = spawn(this.command, this.args, { env: this.env, stdio: ['pipe', 'pipe', 'pipe'] });
    this.child.stdout.setEncoding('utf8');
    this.child.stdout.on('data', frameReader(message => {
      if (message.method === 'engine/cursor') { this.onCursor?.(message.params); return; }
      const entry = this.pending.get(message.id);
      if (!entry) return;
      clearTimeout(entry.timer); this.pending.delete(message.id);
      message.error ? entry.reject(failure('engine_error', message.error.message)) : entry.resolve(message.result);
    }, error => this.fail(error)));
    // Never persist upstream logs, which can contain target application data.
    this.child.stderr.resume();
    this.child.on('error', error => this.fail(error));
    this.child.on('exit', () => { this.ready = null; this.fail(failure('engine_exited', 'Computer engine stopped')); });
    await this.request('initialize', { protocolVersion: '2024-11-05', capabilities: {}, clientInfo: { name: 'opencomputeruse-host', version: '0.1.0' } });
    this.child.stdin.write(JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized' }) + '\n');
  }
  fail(error) { for (const entry of this.pending.values()) { clearTimeout(entry.timer); entry.reject(error); } this.pending.clear(); }
  request(method, params = {}) {
    return new Promise((resolve, reject) => {
      const id = ++this.next;
      const timer = setTimeout(() => { this.pending.delete(id); reject(failure('engine_timeout', 'Engine request timed out')); }, 120_000);
      this.pending.set(id, { resolve, reject, timer });
      this.child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n', error => {
        if (error) { clearTimeout(timer); this.pending.delete(id); reject(error); }
      });
    });
  }
  async readPermissions() {
    const directory = this.env.OCU_COMPUTER_USE_HELPER_COMMAND_DIRECTORY;
    if (!directory) return null;
    const result = await requestComputerUseHelper(directory, 'permissionStatus');
    if (!result.success) throw failure('permission_status_failed', result.error || 'Cannot read native permissions');
    return JSON.parse(result.stdout);
  }
  // Read-only and answered by the helper directly: no engine, observation or workflow.
  async listApplications() {
    const directory = this.env.OCU_COMPUTER_USE_HELPER_COMMAND_DIRECTORY;
    if (!directory) throw failure('helper_unavailable', 'The native helper is unavailable');
    const result = await requestComputerUseHelper(directory, 'listApplications', {}, { timeoutMs: 10_000 });
    if (!result.success) throw failure('application_list_failed', result.error || 'Cannot list running applications');
    return { content: [{ type: 'text', text: JSON.stringify({ applications: JSON.parse(result.stdout) }) }], _meta: { code: 'computer_use_applications', surface: 'use' } };
  }
  // Read-only: the running process an app target names, or null.
  async resolveApplication(target) {
    const directory = this.env.OCU_COMPUTER_USE_HELPER_COMMAND_DIRECTORY;
    if (!directory) return null;
    const result = await requestComputerUseHelper(directory, 'resolveApplication', { appTarget: target }, { timeoutMs: 5_000 });
    return result.success ? JSON.parse(result.stdout).pid ?? null : null;
  }
  async call(name, args, signal) {
    const check = () => { if (signal?.aborted) throw failure('cancelled', 'Execution stopped before dispatch'); };
    check();
    const permissions = await this.readPermissions();
    check();
    if (permissions) {
      // Reading permissions must not reset an unrelated in-flight workflow.
      // The next action/observation preflight handles a changed fingerprint.
      if (name === 'use_permissions') return { content: [{ type: 'text', text: JSON.stringify({ permissions }) }], _meta: { code: 'computer_use_permission_status', surface: 'use' } };
      const fingerprint = JSON.stringify(permissions.map(p => [p.name, p.isGranted]));
      const changed = this.permissionFingerprint !== undefined && this.permissionFingerprint !== fingerprint;
      this.permissionFingerprint = fingerprint;
      if (changed) {
        await this.stop();
        check();
        if (name === 'use_action_batch') throw failure('permissions_changed', 'Native permissions changed. Observe the target again before acting.');
      }
      if (!permissions.find(p => p.name === 'Accessibility')?.isGranted) throw failure('permission_required', 'Enable Accessibility for OpenComputerUse Helper in macOS Settings');
    }
    await this.start(); check(); return this.request('tools/call', { name, arguments: args });
  }
  async list() { await this.start(); return this.request('tools/list'); }
  async releaseNativeFocus(ownerPID) {
    const directory = this.env.OCU_COMPUTER_USE_HELPER_COMMAND_DIRECTORY;
    if (!directory || !ownerPID) return;
    const result = await requestComputerUseHelper(directory, 'releaseActionFocus', { ownerProcessID: ownerPID }, { timeoutMs: 10_000 });
    if (result.success !== true) throw failure('background_focus_cleanup_failed', result.error || 'Native action focus cleanup was not confirmed');
  }
  async reset() {
    await this.releaseNativeFocus(this.child?.pid);
    if (this.ready) await this.request('engine/reset');
  }
  async stop() {
    const child = this.child; this.ready = null;
    this.fail(failure('cancelled', 'Execution stopped; an already dispatched native action may have completed'));
    if (child && child.exitCode === null) await new Promise(resolve => {
      const timer = setTimeout(() => child.kill('SIGKILL'), 2000);
      child.once('exit', () => { clearTimeout(timer); resolve(); });
      child.kill('SIGTERM');
    });
    await this.releaseNativeFocus(child?.pid);
  }
}
