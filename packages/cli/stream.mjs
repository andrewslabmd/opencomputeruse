import net from 'node:net';
import { open, readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { runtimeDirectory, failure } from '../protocol/index.mjs';

export const MAX_STREAM_FRAME = 8 * 1024 * 1024;
const invalid = message => failure('invalid_stream', message);
const startCode = Buffer.from([0, 0, 0, 1]);

export function encodeControl(control) {
  const json = Buffer.from(JSON.stringify(control));
  if (json.length + 1 > MAX_STREAM_FRAME) throw invalid('Stream frame exceeds 8 MiB');
  const frame = Buffer.alloc(5 + json.length);
  frame.writeUInt32BE(json.length + 1); frame[4] = 1; json.copy(frame, 5);
  return frame;
}

// Retains only one incomplete frame; length is checked before allocating its body.
export class StreamDecoder {
  constructor() { this.buffer = Buffer.alloc(4); this.offset = 0; this.body = false; this.failed = false; }
  push(chunk) {
    if (this.failed) throw invalid('Stream decoder already failed');
    const messages = [];
    try {
      for (let offset = 0; offset < chunk.length;) {
        const count = Math.min(this.buffer.length - this.offset, chunk.length - offset);
        chunk.copy(this.buffer, this.offset, offset, offset + count); offset += count; this.offset += count;
        if (this.offset !== this.buffer.length) continue;
        if (!this.body) {
          const length = this.buffer.readUInt32BE();
          if (!length || length > MAX_STREAM_FRAME) throw invalid('Stream frame length must be 1 byte to 8 MiB');
          this.buffer = Buffer.alloc(length); this.offset = 0; this.body = true;
        } else {
          const body = this.buffer;
          if (body[0] === 1) {
            const control = JSON.parse(body.subarray(1).toString('utf8'));
            if (!control || typeof control.type !== 'string') throw invalid('Missing stream control type');
            messages.push({ kind: 'control', control });
          } else if (body[0] === 2) {
            if (body.length < 5) throw invalid('Truncated video header');
            const length = body.readUInt32BE(1);
            if (!length || length > body.length - 5) throw invalid('Invalid video header length');
            const header = JSON.parse(body.subarray(5, 5 + length).toString('utf8'));
            if (!header || typeof header.agent !== 'string' || typeof header.keyframe !== 'boolean' ||
                !Number.isFinite(header.pts) || typeof header.codec !== 'string' || (!header.keyframe && header.format != null)) {
              throw invalid('Invalid video header');
            }
            messages.push({ kind: 'video', header, data: body.subarray(5 + length) });
          } else throw invalid(`Unknown stream frame kind: ${body[0]}`);
          this.buffer = Buffer.alloc(4); this.offset = 0; this.body = false;
        }
      }
      return messages;
    } catch (error) { this.failed = true; this.buffer = Buffer.alloc(0); throw invalid(error.message); }
  }
  finish() { if (this.body || this.offset) throw invalid('Connection closed with an incomplete stream frame'); }
}

export function avccToAnnexB(data, format) {
  const parts = [];
  if (format) {
    for (const key of ['sps', 'pps']) {
      if (!Array.isArray(format[key]) || !format[key].length) throw invalid(`Keyframe format has no ${key.toUpperCase()}`);
      for (const encoded of format[key]) {
        if (typeof encoded !== 'string' || !encoded.length || !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(encoded)) {
          throw invalid('Invalid base64 parameter set');
        }
        parts.push(startCode, Buffer.from(encoded, 'base64'));
      }
    }
  }
  if (!data.length) throw invalid('Empty AVCC sample');
  for (let offset = 0; offset < data.length;) {
    if (data.length - offset < 4) throw invalid('Truncated AVCC NAL length');
    const length = data.readUInt32BE(offset); offset += 4;
    if (!length || length > data.length - offset) throw invalid('Invalid AVCC NAL length');
    parts.push(startCode, data.subarray(offset, offset + length)); offset += length;
  }
  return Buffer.concat(parts);
}

export function selectAgent(agents, name) {
  const matches = agents.filter(agent => agent.agent === name || agent.name === name);
  if (matches.length === 1) return matches[0];
  const available = agents.map(agent => `${agent.name} (${agent.agent})`).join(', ') || '(none; OCU may be stopped)';
  throw failure(matches.length ? 'ambiguous_agent' : 'unknown_agent',
    `${matches.length ? 'Ambiguous' : 'Unknown'} agent ${JSON.stringify(name)}. Available agents: ${available}`);
}

export function streamError(control) {
  const errors = {
    unauthorized: 'The stream token was rejected; use the host-token from the running OCU runtime directory.',
    unsupported_version: `Stream protocol v1 is unsupported. Helper supports versions: ${(control.supported ?? []).join(', ') || '(not provided)'}.`,
    unknown_agent: 'The agent is no longer available; list current agents and select one again.',
    paused: 'OCU is stopped. Choose Resume in OCU before recording.',
    no_permission: 'Screen Recording permission is missing. Review permissions in OCU.',
    codec_unsupported: 'The helper does not support the requested H.264 codec.',
  };
  const ends = {
    released: 'The agent released its app.', disconnected: 'The agent disconnected.',
    stopped: 'OCU is stopped. Choose Resume in OCU before recording.',
    paused: 'OCU is stopped. Choose Resume in OCU before recording.',
    unsubscribed: 'The helper ended the subscription.',
    capture_stopped_by_user: 'Window capture was stopped from macOS. Open Watch or change the agent target to resume capture.',
    error: 'The helper ended capture because of an error.',
  };
  const code = control.type === 'end' ? control.reason : control.code;
  return failure(code, (control.type === 'end' ? ends : errors)[code] || `Unknown stream ${control.type}: ${code}`);
}

export function parseStreamArgs(args) {
  const options = { seconds: 5, fps: 15 };
  const names = { '--agent': 'agent', '--out': 'out', '--seconds': 'seconds', '--fps': 'fps' };
  const seen = new Set();
  for (let i = 0; i < args.length; i++) {
    const name = names[args[i]], value = args[i + 1];
    if (!name || seen.has(name) || !value || value.startsWith('--')) throw Error('Usage: ocu stream --agent NAME_OR_ID --out FILE [--seconds N] [--fps N]');
    seen.add(name); options[name] = ['seconds', 'fps'].includes(name) ? Number(value) : value; i++;
  }
  if (!options.agent || !options.out) throw Error('ocu stream requires --agent NAME_OR_ID and --out FILE');
  // Own choice: cap the duration at the largest Node timer, avoiding timer overflow.
  if (!Number.isFinite(options.seconds) || options.seconds <= 0 || options.seconds * 1000 > 2147483647) throw Error('--seconds must be positive and at most 2147483.647');
  if (!Number.isInteger(options.fps) || options.fps < 1 || options.fps > 30) throw Error('--fps must be an integer from 1 to 30');
  return options;
}

export function streamSummary(result) {
  return `Agent: ${result.agent.name} (${result.agent.agent}); window: ${result.width ?? '?'}x${result.height ?? '?'}; frames: ${result.frames}; keyframes: ${result.keyframes}`;
}

export async function recordStream({ agent, out, seconds = 5, fps = 15, directory = runtimeDirectory(), signal }) {
  parseStreamArgs(['--agent', agent, '--out', out, '--seconds', String(seconds), '--fps', String(fps)]);
  let token;
  try { token = (await readFile(join(directory, 'host-token'), 'utf8')).trim(); }
  catch (error) { throw failure(error.code, `Cannot read the OCU host-token. Open OCU and check OCU_RUNTIME_DIR. ${error.message}`); }
  const socket = net.createConnection(join(directory, 'stream.sock'));
  const decoder = new StreamDecoder();
  const result = { agent: null, frames: 0, keyframes: 0 };
  let file, timer, finished = false, subscribed = false, targetState;
  // Own choice: five seconds to connect and receive the initial agent list.
  let startup = setTimeout(() => socket.destroy(failure('timeout', 'Timed out waiting for the OCU stream agent list.')), 5000);
  const send = control => socket.write(encodeControl(control));
  const stop = () => {
    if (finished) return;
    finished = true;
    if (subscribed && !socket.destroyed) {
      send({ type: 'unsubscribe', agent: result.agent.agent }); subscribed = false;
      socket.end(() => socket.destroy());
    } else socket.destroy();
  };
  const abort = () => socket.destroy(failure('interrupted', 'Stream recording interrupted.'));
  signal?.addEventListener('abort', abort, { once: true });
  socket.once('connect', () => {
    send({ type: 'hello', token, client: 'ocu stream', version: 1 });
    send({ type: 'list' });
  });
  try {
    if (signal?.aborted) abort();
    for await (const chunk of socket) {
      for (const message of decoder.push(chunk)) {
        if (finished) break;
        if (message.kind === 'control') {
          const control = message.control;
          if (control.type === 'error' || (control.type === 'end' && control.agent === result.agent?.agent)) throw streamError(control);
          if (control.type === 'agents' && !result.agent) {
            if (!Array.isArray(control.agents)) throw invalid('Invalid agent list');
            result.agent = selectAgent(control.agents, agent);
            file = await open(out, 'w', 0o600);
            clearTimeout(startup); startup = null;
            send({ type: 'subscribe', agent: result.agent.agent, max_fps: fps, codec: 'h264' }); subscribed = true;
            timer = setTimeout(stop, seconds * 1000);
          } else if (control.type === 'target' && control.agent === result.agent?.agent) {
            targetState = control.state;
            if (Array.isArray(control.frame)) { result.width = control.frame[2]; result.height = control.frame[3]; }
            if (control.state === 'stopped') throw streamError({ type: 'error', code: 'paused' });
            if (control.state === 'no_permission') throw streamError({ type: 'error', code: 'no_permission' });
          }
        } else if (message.header.agent === result.agent?.agent) {
          const { header, data } = message;
          if (header.codec !== 'h264') throw streamError({ type: 'error', code: 'codec_unsupported' });
          if (!result.frames && !header.keyframe) continue;
          if (header.keyframe && !header.format) throw invalid('H.264 keyframe is missing its parameter sets');
          await file.writeFile(avccToAnnexB(data, header.format));
          result.frames++; if (header.keyframe) result.keyframes++;
        }
      }
    }
    if (!finished) { decoder.finish(); throw failure('stream_disconnected', 'The OCU stream socket closed before the recording finished.'); }
    if (!result.frames) throw failure('no_frames', `No H.264 keyframe received; window state: ${targetState ?? 'unknown'}.`);
    return result;
  } catch (error) {
    if (finished && error.code === 'ERR_STREAM_PREMATURE_CLOSE') {
      if (result.frames) return result;
      error = failure('no_frames', `No H.264 keyframe received; window state: ${targetState ?? 'unknown'}.`);
    }
    if (['ENOENT', 'ECONNREFUSED'].includes(error.code) && !result.agent) {
      error = failure(error.code, 'The OCU stream socket is unavailable. Open OCU and check OCU_RUNTIME_DIR.');
    }
    error.summary = result.agent ? result : undefined;
    throw error;
  } finally {
    clearTimeout(startup); clearTimeout(timer); signal?.removeEventListener('abort', abort);
    if (subscribed && !socket.destroyed) {
      send({ type: 'unsubscribe', agent: result.agent.agent });
      socket.end(() => socket.destroy());
    } else socket.destroy();
    await file?.close();
  }
}

export async function runStream(args) {
  const controller = new AbortController();
  const interrupt = () => controller.abort();
  process.once('SIGINT', interrupt); process.once('SIGTERM', interrupt);
  try {
    const result = await recordStream({ ...parseStreamArgs(args), signal: controller.signal });
    console.log(streamSummary(result)); return 0;
  } catch (error) {
    if (error.summary) console.log(streamSummary(error.summary));
    console.error(`${error.code || 'error'}: ${error.message}`); return 1;
  } finally { process.removeListener('SIGINT', interrupt); process.removeListener('SIGTERM', interrupt); }
}
