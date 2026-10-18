import net from 'node:net';
import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { dirname, resolve } from 'node:path';
import { spawn, spawnSync } from 'node:child_process';
import { VERSION, frameReader, failure, runtimeDirectory } from '../protocol/index.mjs';
const interrupted = () => failure('host_disconnected', 'The OpenComputerUse host connection closed during this request (the host may have restarted). It was not retried and an action may already have been performed; observe again before continuing.');
const revoked = () => failure('revoked', 'This client was disconnected from the OpenComputerUse menu-bar app. Restart the agent\'s OpenComputerUse connection to use it again.');
const readOnly = (method, params) => method === 'status' || method === 'tools/list' || (method === 'tools/call' && ['use_permissions', 'use_list_apps'].includes(params?.name));
// One connection at a time. A request on a closed connection reconnects and
// registers again; requests in flight when it closed fail once, never replayed.
export class Client {
  constructor(directory = runtimeDirectory(), { name = 'CLI', reconnectMs = 10_000 } = {}) { this.directory = directory; this.name = name; this.reconnectMs = reconnectMs; this.next = 0; this.conn = null; }
  get connected() { return Boolean(this.conn?.open && this.conn.ready); }
  async connect(name = this.name) {
    this.name = name; this.closed = false; this.conn?.socket.destroy();
    const conn = this.conn = { socket: net.connect(join(this.directory, 'host.sock')), pending: new Map(), open: true, ready: false };
    const { socket } = conn; socket.setEncoding('utf8');
    const drop = error => { conn.open = false; for (const p of conn.pending.values()) { clearTimeout(p.timer); p.reject(conn.revoked ? revoked() : error); } conn.pending.clear(); };
    socket.on('data', frameReader(m => {
      if (m.method === 'revoked' && m.id === undefined) { conn.revoked = this.revoked = true; return; }
      const p = conn.pending.get(m.id); if (!p) return; conn.pending.delete(m.id); clearTimeout(p.timer); m.error ? p.reject(failure(m.error.code, m.error.message)) : p.resolve(m.result);
    }, e => { drop(e); socket.destroy(); }));
    socket.on('error', () => drop(interrupted())); socket.on('end', () => drop(interrupted())); socket.on('close', () => drop(interrupted()));
    await new Promise((resolve, reject) => { socket.once('connect', resolve); socket.once('error', reject); });
    try {
      const token = (await readFile(join(this.directory, 'host-token'), 'utf8')).trim();
      await this.send(conn, 'hello', undefined, { token, name }); conn.ready = true; return this;
    } catch (error) { socket.destroy(); throw error; }
  }
  // Reconnects only before sending, so an interrupted request is never sent twice.
  async ensure() {
    if (this.connected) return this.conn;
    if (this.closed) throw failure('disconnected', 'Client is closed');
    if (this.revoked) throw revoked();
    await (this.connecting ||= connectHost(this, this.name, { waitMs: this.reconnectMs }).finally(() => { this.connecting = null; }));
    return this.conn;
  }
  async request(method, params, extra = {}) {
    try { return await this.send(await this.ensure(), method, params, extra); }
    catch (error) {
      // Read-only requests cannot change anything, so one interrupted by a
      // restart is sent again to the new host. Observations and actions are not.
      if (error.code !== 'host_disconnected' || !readOnly(method, params) || this.closed) throw error;
      return this.send(await this.ensure(), method, params, extra);
    }
  }
  send(conn, method, params, extra = {}) {
    return new Promise((resolve, reject) => {
      if (!conn.open) { reject(interrupted()); return; }
      const id = ++this.next; const timer = setTimeout(() => { conn.pending.delete(id); reject(failure('timeout', 'Host request timed out')); }, 125000);
      conn.pending.set(id, { resolve, reject, timer });
      conn.socket.write(JSON.stringify({ v: VERSION, id, method, params, ...extra }) + '\n', error => { if (error && conn.pending.delete(id)) { clearTimeout(timer); reject(interrupted()); } });
    });
  }
  close() { this.closed = true; this.conn?.socket.end(); }
}

// Connects, launching the enclosing app when its host is not listening, and
// waits up to waitMs for a host that is starting or restarting.
export async function connectHost(client, name, { waitMs } = {}) {
  try { return await client.connect(name); }
  catch (error) {
    if (!['ENOENT', 'ECONNREFUSED'].includes(error.code)) throw error;
    const app = resolve(dirname(process.execPath), '../..');
    const bundled = app.endsWith('.app');
    if (!bundled && !waitMs) throw error;
    // Launch the app only when it is not running: a running app restarts its own
    // host, and opening it again would bring up its window.
    const running = bundled && spawnSync('/usr/bin/pgrep', ['-f', `${app}/Contents/MacOS/OpenComputerUse$`]).status === 0;
    if (bundled && !running) await new Promise((res, rej) => { const p = spawn('/usr/bin/open', ['-g', app]); p.on('error', rej); p.on('exit', c => c === 0 ? res() : rej(new Error('Host launch failed'))); });
    for (const deadline = Date.now() + (waitMs ?? 10_000); Date.now() < deadline;) {
      await new Promise(r => setTimeout(r, 250));
      try { return await client.connect(name); } catch { client.conn?.socket.destroy(); }
    }
    throw failure('host_unavailable', 'The OpenComputerUse host is not running. Open the OpenComputerUse menu-bar app; if it shows Unavailable, choose Restart Services (its status shows the reason).');
  }
}
