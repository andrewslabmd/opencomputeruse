import { join } from 'node:path';
import { Host } from './server.mjs';
import { Broker } from './broker.mjs';
import { runtimeDirectory } from '../protocol/index.mjs';
const directory = runtimeDirectory();
const parent = process.env.OCU_PARENT_PID ? Number(process.env.OCU_PARENT_PID) : null;
if (parent !== null && (!Number.isInteger(parent) || parent <= 0)) throw new Error('Invalid parent PID');
// One private engine per agent workflow, started on its first observation or action.
const host = new Host({ directory, createBroker: () => new Broker(process.env.OCU_ENGINE_PATH, [], process.env), parentPid: parent });
// The app shows the last stderr line when the host exits.
try { await host.start(); }
catch (error) { process.stderr.write(`${error.code || 'host_error'}: ${error.message}\n`); process.exit(1); }
let closing = false;
async function close() {
  if (closing) return; closing = true;
  // Native cleanup can wait on a helper that exited with the app; the socket
  // is already released, so it never delays a replacement host for long.
  setTimeout(() => process.exit(0), 3000).unref();
  await host.close().catch(() => {}); process.exit(0);
}
process.on('SIGTERM', close); process.on('SIGINT', close);
if (parent) {
  // Reparenting also means the app exited, even if its PID was reused.
  setInterval(() => { try { process.kill(parent, 0); if (process.ppid !== parent) void close(); } catch (error) { if (error.code === 'ESRCH') void close(); } }, 1000).unref();
}
