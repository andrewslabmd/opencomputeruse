import net from 'node:net';
import { mkdir, chmod, readFile, writeFile, rename, unlink, lstat } from 'node:fs/promises';
import { randomBytes, timingSafeEqual, randomUUID } from 'node:crypto';
import { join } from 'node:path';
import { VERSION, frameReader, failure } from '../protocol/index.mjs';
import Ajv from 'ajv';
import { tools } from '../protocol/tools.mjs';
import { Client } from '../cli/client.mjs';
const ajv = new Ajv({ strict: false });
const validators = new Map(tools.map(tool => [tool.name, ajv.compile(tool.inputSchema)]));

// Each client gets its own workflow: a private engine (broker) and at most one
// claimed application. Agents work in different apps at the same time; a
// second agent asking for an app another agent has claimed receives busy.
export class Host {
  // `broker` alone (tests, fixtures) shares one engine between every workflow.
  constructor({ directory, createBroker, broker, idleMs = 120_000, parentPid = null }) {
    this.directory = directory; this.createBroker = createBroker ?? (() => broker); this.idleMs = idleMs; this.parentPid = parentPid;
    // Read-only requests (permissions, app list, target resolution) never start an engine.
    this.reader = this.createBroker();
    this.clients = new Map(); this.workflows = new Map(); this.stopping = false; this.paused = false;
  }
  get inflight() { return [...this.workflows.values()].some(w => w.inflight); }
  // The most recently active workflow that holds an app (the menu-bar preview follows it).
  get owner() { return [...this.workflows.values()].filter(w => w.pid != null).sort((a, b) => b.lastActivity - a.lastActivity)[0]?.id ?? null; }
  workflow(id) {
    let wf = this.workflows.get(id);
    if (!wf) {
      // A stable small slot per workflow gives each agent its own cursor color.
      const used = new Set([...this.workflows.values()].map(w => w.slot));
      let slot = 0; while (used.has(slot)) slot++;
      wf = { id, slot, broker: this.createBroker(), pid: null, claiming: null, cursor: null, inflight: false, stopping: false, active: null, lastActivity: Date.now() };
      wf.broker.onCursor = event => this.cursor(wf, event);
      this.workflows.set(id, wf);
    }
    return wf;
  }
  cursor(wf, event) {
    const finite = n => Number.isFinite(n);
    if (!event || !Number.isInteger(event.pid) || !Number.isInteger(event.window_id) || !finite(event.x) || !finite(event.y)) return;
    wf.cursor = { pid: event.pid, window_id: event.window_id, x: event.x, y: event.y, kind: String(event.kind || 'action').slice(0, 32),
      ...(finite(event.to_x) && finite(event.to_y) ? { to_x: event.to_x, to_y: event.to_y } : {}), at: Date.now() };
    void this.publishCursors().catch(() => {});
  }
  // The menu-bar app draws one cursor per agent above the window it acts in.
  // Only workflows that still hold the app the cursor belongs to are listed.
  cursors() {
    return [...this.workflows.values()].filter(w => w.cursor && w.pid === w.cursor.pid && !w.stopping)
      .map(w => ({ client: w.id, name: this.clients.get(w.id)?.name ?? 'Agent', slot: w.slot, ...w.cursor }));
  }
  async publishCursors() {
    if (this.closingCursors) return;
    const data = JSON.stringify(this.cursors());
    if (data === this.lastCursors) return;
    this.lastCursors = data;
    this.cursorWriting = (this.cursorWriting || Promise.resolve()).catch(() => {}).then(async () => {
      const path = join(this.directory, 'cursors.json'); const temp = path + '.' + randomUUID();
      await writeFile(temp, data, { mode: 0o600 }); await rename(temp, path);
    });
    return this.cursorWriting;
  }
  claimant(pid, except) { return [...this.workflows.values()].find(w => w.id !== except && (w.pid === pid || w.claiming === pid)); }
  async resolve(target) {
    if (typeof target !== 'string' || !target.trim() || !this.reader.resolveApplication) return null;
    try { return await this.reader.resolveApplication(target.trim()); } catch { return null; }
  }
  async start() {
    await mkdir(this.directory, { recursive: true, mode: 0o700 });
    const stat = await lstat(this.directory);
    if (stat.isSymbolicLink() || stat.uid !== process.getuid()) throw failure('unsafe_directory', 'Runtime directory must belong to this user');
    await chmod(this.directory, 0o700);
    const tokenPath = join(this.directory, 'host-token');
    try {
      const tokenStat = await lstat(tokenPath);
      if (!tokenStat.isFile() || tokenStat.uid !== process.getuid()) throw failure('unsafe_token', 'Host token must be a file owned by this user');
      this.token = (await readFile(tokenPath, 'utf8')).trim();
      if (!/^[a-f0-9]{64}$/.test(this.token)) throw failure('invalid_token', 'Host token needs local repair');
    }
    catch (error) { if (error.code !== 'ENOENT') throw error; this.token = randomBytes(32).toString('hex'); await writeFile(tokenPath, this.token, { mode: 0o600, flag: 'wx' }); }
    await chmod(tokenPath, 0o600);
    this.socketPath = join(this.directory, 'host.sock');
    // A responsive socket is never removed while its host is current. The
    // enclosing app also holds flock, so a host whose app has exited is stale.
    if (await this.listening()) await this.replaceStaleHost();
    await this.restorePause();
    await unlink(this.socketPath).catch(error => { if (error.code !== 'ENOENT') throw error; });
    this.server = net.createServer(socket => this.connect(socket));
    await new Promise((resolve, reject) => { this.server.once('error', reject); this.server.listen(this.socketPath, resolve); });
    await chmod(this.socketPath, 0o600);
    this.socketInode = (await lstat(this.socketPath)).ino;
    this.timer = setInterval(() => { void this.expireIdleOwner(); }, 1000);
    this.timer.unref(); await this.publish();
  }
  listening() { return new Promise((resolve, reject) => { const s = net.connect(this.socketPath); s.once('connect', () => { s.destroy(); resolve(true); }); s.once('error', error => ['ENOENT', 'ECONNREFUSED'].includes(error.code) ? resolve(false) : reject(error)); }); }
  // Asks the listening host who it is. A host whose app (parent) has exited,
  // or that is shutting down, is stopped; any other host stays authoritative.
  async replaceStaleHost() {
    let existing = null;
    try {
      const client = new Client(this.directory, { name: 'Host startup', reconnectMs: 0 });
      existing = await Promise.race([client.connect().then(c => c.request('status')).finally(() => client.close()), new Promise((_, reject) => setTimeout(() => reject(failure('timeout', 'No answer')), 3000).unref())]);
    } catch {}
    const pid = existing?.pid;
    if (!Number.isInteger(pid) || pid <= 0 || pid === process.pid) {
      // An older or unresponsive host: give it time to exit by itself.
      for (let i = 0; i < 50; i++) { await sleep(100); if (!await this.listening()) return; }
      throw failure('already_running', `Another OpenComputerUse host is holding ${this.socketPath} and did not identify itself. Quit OpenComputerUse, end any remaining ocu-host process in Activity Monitor, then open the app again.`);
    }
    const stale = existing.closing || existing.orphaned || (existing.parent_pid ? !alive(existing.parent_pid) : false);
    if (!stale) throw failure('already_running', `OpenComputerUse host ${pid} is already running${existing.parent_pid ? ` for app process ${existing.parent_pid}` : ''}. Quit that app (or stop that host) first.`);
    await stopProcess(pid);
  }
  connect(socket) {
    const id = randomUUID(); const client = { id, socket, authenticated: false };
    this.clients.set(id, client); socket.setEncoding('utf8');
    const authTimer = setTimeout(() => { if (!client.authenticated) socket.destroy(); }, 5000);
    socket.on('error', () => {});
    socket.on('close', () => { clearTimeout(authTimer); this.clients.delete(id); if (!this.closing) void this.disconnect(id).catch(() => {}); void this.publish(); });
    socket.on('data', frameReader(message => { void this.handle(client, message).then(result => {
      if (!socket.destroyed) socket.write(JSON.stringify({ v: VERSION, id: message.id, result }) + '\n');
    }).catch(error => { if (!socket.destroyed) socket.write(JSON.stringify({ v: VERSION, id: message.id, error: { code: error.code || 'host_error', message: error.message } }) + '\n'); }); }, () => socket.destroy()));
  }
  async handle(client, message) {
    if (message.v !== VERSION) throw failure('version_mismatch', 'Unsupported host protocol version');
    if (!client.authenticated) {
      const provided = Buffer.from(String(message.token || '')); const expected = Buffer.from(this.token);
      if (message.method !== 'hello' || provided.length !== expected.length || !timingSafeEqual(provided, expected)) throw failure('unauthorized', 'Local authorization required');
      client.authenticated = true; client.name = String(message.name || 'Local client').slice(0, 100); await this.publish(); return { client: client.id, version: VERSION };
    }
    switch (message.method) {
      case 'status': return this.status();
      case 'resume': await this.setPaused(false); await this.publish(); return this.status();
      case 'pause':
        try { await this.setPaused(true); }
        finally { await this.cancelAll(); }
        return this.status();
      case 'revoke': {
        const target = this.clients.get(message.params?.client);
        if (!target) throw failure('unknown_client', 'Client is no longer connected');
        // Tells the client not to reconnect by itself, then disconnects it.
        target.socket.end(JSON.stringify({ v: VERSION, method: 'revoked' }) + '\n'); setTimeout(() => target.socket.destroy(), 1000).unref();
        return { disconnected: true };
      }
      // A client cancels only its own workflow; the app's Stop control stops all.
      case 'cancel': return this.cancel(client.id);
      case 'release': return this.release(client.id);
      case 'tools/list': return { tools };
      case 'tools/call': return this.call(client, message.params || {});
      default: throw failure('unknown_method', 'Unknown host method');
    }
  }
  status() {
    const claimed = [...this.workflows.values()].filter(w => w.pid != null);
    const cleanupError = [...this.workflows.values()].find(w => w.cleanupError)?.cleanupError;
    return { version: VERSION, pid: process.pid, parent_pid: this.parentPid, ...(this.closing ? { closing: true } : {}), ...(this.parentPid && process.ppid !== this.parentPid ? { orphaned: true } : {}), paused: this.paused, busy: this.inflight, stopping: this.stopping || [...this.workflows.values()].some(w => w.stopping), owner: this.owner, ...(cleanupError ? { cleanup_error: cleanupError } : {}),
      workflows: claimed.map(w => ({ client: w.id, app_pid: w.pid, busy: w.inflight })),
      clients: [...this.clients.values()].filter(c => c.authenticated).map(c => ({ id: c.id, name: c.name, ownsExecution: claimed.some(w => w.id === c.id) })) };
  }
  async restorePause() {
    for (const name of ['control-state.json', 'status.json']) {
      try {
        const path = join(this.directory, name), stat = await lstat(path);
        if (!stat.isFile() || stat.uid !== process.getuid()) throw failure('unsafe_control_state', 'Control state must be a file owned by this user');
        const state = JSON.parse(await readFile(path, 'utf8'));
        this.paused = typeof state.paused === 'boolean' ? state.paused : true;
        return;
      } catch (error) {
        if (error.code === 'ENOENT') continue;
        // Damaged state cannot silently turn off an earlier Pause.
        this.paused = true; return;
      }
    }
  }
  async setPaused(paused) {
    const revision = this.controlRevision = (this.controlRevision || 0) + 1;
    if (paused) this.paused = true;
    const operation = (this.controlWriting || Promise.resolve()).catch(() => {}).then(async () => {
      const path = join(this.directory, 'control-state.json'), temp = path + '.' + randomUUID();
      try {
        await writeFile(temp, JSON.stringify({ paused }), { mode: 0o600, flag: 'wx' });
        await rename(temp, path);
      } finally { await unlink(temp).catch(() => {}); }
      // A later Pause takes effect immediately, even while a Resume is saving.
      if (!paused && revision === this.controlRevision) this.paused = false;
    });
    this.controlWriting = operation;
    return operation;
  }
  async expireIdleOwner() {
    for (const wf of [...this.workflows.values()]) {
      if (wf.pid == null || wf.inflight || wf.stopping || this.stopping || Date.now() - wf.lastActivity <= this.idleMs) continue;
      try { await this.release(wf.id); }
      catch (error) {
        // Native cleanup can fail while an app is unresponsive. Preserve its
        // ownership and actual error, and keep the control server alive. Retry
        // only at the existing idle interval, never in a tight timer loop.
        wf.cleanupError = { code: error.code || 'host_error', message: error.message };
        wf.lastActivity = Date.now();
        await this.publish().catch(() => {});
      }
    }
  }
  async publish() {
    if (this.closing) return;
    void this.publishCursors().catch(() => {});
    const data = JSON.stringify(this.status());
    this.publishing = (this.publishing || Promise.resolve()).then(async () => {
      const path = join(this.directory, 'status.json'); const temp = path + '.' + randomUUID();
      await writeFile(temp, data, { mode: 0o600 }); await rename(temp, path);
    });
    return this.publishing;
  }
  async call(client, { name, arguments: args = {} }) {
    if (!['use_observe', 'use_action_batch', 'use_permissions', 'use_list_apps'].includes(name)) throw failure('unknown_tool', 'Tool is not exposed');
    if (!validators.get(name)(args)) throw failure('invalid_arguments', 'Arguments do not match the tool schema');
    // Permission inspection is read-only and does not replace the workflow,
    // its abort controller or its in-flight state. Stop/paused state also must
    // not prevent the user/agent inspecting why actions are unavailable.
    if (name === 'use_permissions') return this.reader.call(name, args);
    // Listing apps is read-only too and leaves every workflow alone, but window
    // titles are app content: Stop pauses it like observation.
    if (name === 'use_list_apps') {
      if (this.paused) throw failure('paused', 'Resume Computer Use in the menu-bar app');
      return this.reader.listApplications();
    }
    if (this.stopping) throw failure('busy', 'A stop is in progress');
    if (this.paused) throw failure('paused', 'Resume Computer Use in the menu-bar app');
    const wf = this.workflow(client.id);
    if (wf.inflight || wf.stopping) throw failure('busy', 'This client already has an action or stop in progress');
    const launch = name === 'use_action_batch' ? args.actions?.find(a => a?.kind === 'open_app') : undefined;
    if (wf.pid == null && name === 'use_action_batch' && args.actions?.[0]?.kind !== 'open_app') throw failure('observation_required', 'Observe the target before taking actions');
    // Claim the app before anything is collected or sent, so two agents never
    // work in the same app. A target that is not running yet is claimed from
    // the result (its new process) instead.
    wf.inflight = true; wf.lastActivity = Date.now();
    const active = new AbortController(); wf.active = active;
    try {
      const target = name === 'use_observe' ? args.app_target : launch ? (launch.bundle_id || launch.name) : undefined;
      const pid = target ? await this.resolve(target) : null;
      if (pid != null) {
        if (this.claimant(pid, wf.id)) throw failure('busy', 'Another agent is working in this application. Choose another app or wait for it to finish.');
        wf.claiming = pid;
      }
      if (this.paused || this.stopping || active.signal.aborted) throw failure('cancelled', 'Execution stopped before dispatch');
      await this.publish();
      const result = await wf.broker.call(name, args, active.signal);
      const actual = result?._meta?.pid;
      if (Number.isInteger(actual)) {
        if (this.claimant(actual, wf.id)) {
          // Only reachable when the target changed process during the call.
          await wf.broker.reset().catch(() => {}); wf.pid = null;
          throw failure('busy', 'Another agent is working in this application. Observe a different app.');
        }
        wf.pid = actual;
      } else if (name === 'use_observe' || (name === 'use_action_batch' && !result?.isError)) wf.pid = null;
      return result;
    } finally {
      wf.claiming = null;
      if (wf.active === active) wf.active = null;
      wf.inflight = false; wf.lastActivity = Date.now(); await this.publish();
    }
  }
  async release(id) {
    const wf = this.workflows.get(id);
    if (!wf || wf.pid == null) return { released: false };
    if (wf.inflight || wf.stopping) throw failure('busy', 'Wait for the current action before releasing');
    wf.stopping = true;
    try { await wf.broker.reset(); wf.pid = null; wf.cursor = null; wf.cleanupError = null; return { released: true }; }
    finally { wf.stopping = false; await this.publish(); }
  }
  async cancel(id) {
    const wf = this.workflows.get(id);
    if (!wf) return { cancelled: false };
    if (wf.stopping) return { stopping: true };
    wf.stopping = true; wf.active?.abort(); await this.publish();
    try { await wf.broker.stop(); wf.pid = null; wf.cursor = null; wf.cleanupError = null; return { cancelled: true, note: 'An already dispatched native action may have completed. Observe again before continuing.' }; }
    finally { wf.stopping = false; await this.publish(); }
  }
  // The app's Stop control: every workflow stops.
  async cancelAll() {
    if (this.stopping) return { stopping: true };
    this.stopping = true; await this.publish();
    try { await Promise.all([...this.workflows.keys()].map(id => this.cancel(id))); return { cancelled: true }; }
    finally { this.stopping = false; await this.publish(); }
  }
  // A departed client's engine is stopped and its app claim ends.
  async disconnect(id) {
    if (!this.workflows.has(id)) return;
    try { await this.cancel(id); } finally { this.workflows.delete(id); }
  }
  // Stops listening first, so a replacement host can start while native
  // cleanup finishes, and removes the socket path only while it is still ours.
  close() { return this.closed ||= this.shutdown(); }
  async shutdown() {
    this.closing = true; for (const wf of this.workflows.values()) wf.active?.abort(); clearInterval(this.timer);
    const closed = new Promise(resolve => this.server.close(resolve));
    if ((await lstat(this.socketPath).catch(() => null))?.ino === this.socketInode) await unlink(this.socketPath).catch(() => {});
    for (const c of this.clients.values()) c.socket.destroy();
    // No agent is acting once the host is gone: leave no cursor behind.
    this.closingCursors = true; await this.cursorWriting?.catch(() => {});
    await writeFile(join(this.directory, 'cursors.json'), '[]', { mode: 0o600 }).catch(() => {});
    await Promise.all([this.reader, ...[...this.workflows.values()].map(w => w.broker)].map(b => b.stop().catch(() => {}))); await closed; await this.publishing;
  }
}
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
function alive(pid) { try { process.kill(pid, 0); return true; } catch (error) { return error.code === 'EPERM'; } }
async function stopProcess(pid) {
  for (const [signal, waitMs] of [['SIGTERM', 3000], ['SIGKILL', 2000]]) {
    try { process.kill(pid, signal); } catch (error) { if (error.code === 'ESRCH') return; throw failure('stale_host', `A previous OpenComputerUse host (${pid}) cannot be stopped: ${error.message}`); }
    for (let waited = 0; waited < waitMs; waited += 50) { await sleep(50); if (!alive(pid)) return; }
  }
  throw failure('stale_host', `A previous OpenComputerUse host (${pid}) did not exit. End it in Activity Monitor, then choose Restart Services.`);
}
