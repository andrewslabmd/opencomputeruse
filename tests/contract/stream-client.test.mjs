import test from 'node:test';
import assert from 'node:assert/strict';
import net from 'node:net';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { mkdtemp, readFile, writeFile, rm, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { StreamDecoder, MAX_STREAM_FRAME, encodeControl, avccToAnnexB, recordStream, parseStreamArgs, streamError } from '../../packages/cli/stream.mjs';

const exec = promisify(execFile);
// Own synthetic fixture choices: 640×480, two-byte NAL payloads, 50–150 ms clips
// and a 2 s timing ceiling keep these headless transport tests small.
// Fake server framing is deliberately independent of the production encoder/decoder.
const frame = (kind, data) => { const n = Buffer.alloc(4); n.writeUInt32BE(1 + data.length); return Buffer.concat([n, Buffer.from([kind]), data]); };
const control = object => frame(1, Buffer.from(JSON.stringify(object)));
const avcc = (...nals) => Buffer.concat(nals.map(nal => { const bytes = Buffer.from(nal), n = Buffer.alloc(4); n.writeUInt32BE(bytes.length); return Buffer.concat([n, bytes]); }));
const sets = { sps: [Buffer.from([0x67, 0x42]).toString('base64')], pps: [Buffer.from([0x68, 0xce]).toString('base64')] };
const agents = [{ agent: 'id-1', name: 'Test agent', color_slot: 0, busy: true, state: 'live' }];
const video = (keyframe = true, pts = 1) => {
  const header = Buffer.from(JSON.stringify({ agent: 'id-1', pts, keyframe, codec: 'h264', ...(keyframe ? { format: sets } : {}) }));
  const length = Buffer.alloc(4); length.writeUInt32BE(header.length);
  return frame(2, Buffer.concat([length, header, avcc([keyframe ? 0x65 : 0x41, pts])]));
};
const target = control({ type: 'target', agent: 'id-1', pid: 10, window_id: 20, frame: [0, 0, 640, 480], scale: 1, state: 'live' });
const annex = (...nals) => Buffer.concat(nals.map(nal => Buffer.from([0, 0, 0, 1, ...nal])));

async function server(t, respond) {
  const directory = await mkdtemp(join(tmpdir(), 'ocu-sc-'));
  await writeFile(join(directory, 'host-token'), 'test-secret\n', { mode: 0o600 });
  const sockets = new Set(), received = [], errors = [];
  const listener = net.createServer(socket => {
    sockets.add(socket); socket.on('close', () => sockets.delete(socket)); socket.on('error', () => {});
    let buffer = Buffer.alloc(0);
    socket.on('data', chunk => {
      buffer = Buffer.concat([buffer, chunk]);
      try {
        while (buffer.length >= 4 && buffer.length >= 4 + buffer.readUInt32BE()) {
          const size = buffer.readUInt32BE(); assert.equal(buffer[4], 1);
          const message = JSON.parse(buffer.subarray(5, 4 + size)); buffer = buffer.subarray(4 + size);
          received.push(message); respond(message, socket, sockets, received);
        }
      } catch (error) { errors.push(error); socket.destroy(); }
    });
  });
  await new Promise((resolve, reject) => { listener.once('error', reject); listener.listen(join(directory, 'stream.sock'), resolve); });
  t.after(async () => {
    for (const socket of sockets) socket.destroy();
    await new Promise(resolve => listener.close(resolve)); await rm(directory, { recursive: true, force: true });
    assert.deepEqual(errors, []);
  });
  return { directory, received, out: join(directory, 'clip.h264') };
}
const basic = (message, socket) => {
  if (message.type === 'hello') assert.deepEqual(message, { type: 'hello', token: 'test-secret', client: 'ocu stream', version: 1 });
  if (message.type === 'list') socket.write(control({ type: 'agents', agents }));
  if (message.type === 'subscribe') socket.write(Buffer.concat([target, video(false, 0), video(true), video(false, 2), video(true, 3)]));
};

test('control framing round trip, coalesced video and every partial-read boundary', () => {
  const hello = { type: 'hello', token: 'token', client: 'ocu stream', version: 1 };
  assert.deepEqual(encodeControl(hello), control(hello));
  const bytes = Buffer.concat([control(hello), video()]);
  for (let split = 0; split <= bytes.length; split++) {
    const decoder = new StreamDecoder(), messages = [...decoder.push(bytes.subarray(0, split)), ...decoder.push(bytes.subarray(split))];
    decoder.finish(); assert.equal(messages.length, 2); assert.deepEqual(messages[0].control, hello);
    assert.deepEqual(messages[1].data, avcc([0x65, 1])); assert.deepEqual(messages[1].header.format, sets);
  }
  const decoder = new StreamDecoder();
  assert.equal([...bytes].flatMap(byte => decoder.push(Buffer.from([byte]))).length, 2); decoder.finish();
});

test('framing enforces the 8 MiB body limit, kind, JSON, video header and incomplete EOF', () => {
  for (const size of [0, MAX_STREAM_FRAME + 1]) {
    const decoder = new StreamDecoder(), bytes = Buffer.alloc(4); bytes.writeUInt32BE(size);
    assert.throws(() => decoder.push(bytes), /1 byte to 8 MiB/); assert.throws(() => decoder.push(control({ type: 'list' })), /already failed/);
  }
  const body = Buffer.alloc(MAX_STREAM_FRAME - 1, 32), json = Buffer.from('{"type":"list"}'); json.copy(body);
  assert.equal(new StreamDecoder().push(frame(1, body))[0].control.type, 'list');
  for (const bytes of [frame(3, Buffer.alloc(0)), frame(1, Buffer.from('{')), frame(2, Buffer.alloc(3)), frame(2, Buffer.from([0, 0, 0, 9]))]) {
    assert.throws(() => new StreamDecoder().push(bytes), { code: 'invalid_stream' });
  }
  const decoder = new StreamDecoder(); decoder.push(control({ type: 'list' }).subarray(0, 6)); assert.throws(() => decoder.finish(), /incomplete/);
});

test('AVCC becomes Annex B, SPS/PPS precede the keyframe and each NAL gets a start code', () => {
  assert.deepEqual(avccToAnnexB(avcc([0x65, 1], [0x06, 2]), sets), annex([0x67, 0x42], [0x68, 0xce], [0x65, 1], [0x06, 2]));
  for (const bytes of [Buffer.alloc(0), Buffer.from([0, 0]), Buffer.from([0, 0, 0, 4, 1]), Buffer.alloc(4)]) assert.throws(() => avccToAnnexB(bytes), /AVCC/);
  assert.throws(() => avccToAnnexB(avcc([1]), { sps: ['!!'], pps: sets.pps }), /base64/);
});

for (const agent of ['Test agent', 'id-1']) test(`records by ${agent}, authenticates, starts at first keyframe, stops and unsubscribes`, async t => {
  const fake = await server(t, basic), started = performance.now();
  const result = await recordStream({ ...fake, agent, seconds: 0.1, fps: 12 });
  assert.ok(performance.now() - started >= 90); assert.ok(performance.now() - started < 2000);
  assert.equal(result.frames, 3); assert.equal(result.keyframes, 2); assert.equal(result.width, 640); assert.equal(result.height, 480);
  assert.deepEqual(await readFile(fake.out), annex([0x67, 0x42], [0x68, 0xce], [0x65, 1], [0x41, 2], [0x67, 0x42], [0x68, 0xce], [0x65, 3]));
  assert.equal((await stat(fake.out)).mode & 0o777, 0o600);
  // The client's FIN follows unsubscribe; allow the fake's data handler to consume it.
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(fake.received.map(m => m.type), ['hello', 'list', 'subscribe', 'unsubscribe']);
  assert.deepEqual(fake.received[2], { type: 'subscribe', agent: 'id-1', max_fps: 12, codec: 'h264' });
});

test('client accepts fragmented server frames and ignores pushed agent lists after selecting', async t => {
  const fake = await server(t, (message, socket) => {
    if (message.type === 'list') {
      const bytes = control({ type: 'agents', agents });
      for (const byte of bytes) socket.write(Buffer.from([byte]));
    }
    if (message.type === 'subscribe') {
      const bytes = Buffer.concat([control({ type: 'agents', agents: [] }), target, video()]);
      socket.write(bytes.subarray(0, 7)); setImmediate(() => socket.write(bytes.subarray(7)));
    }
  });
  assert.equal((await recordStream({ ...fake, agent: 'id-1', seconds: 0.1 })).frames, 1);
});

for (const [name, list, code] of [
  ['missing', agents, 'unknown_agent'],
  ['Test agent', [...agents, { ...agents[0], agent: 'id-2' }], 'ambiguous_agent'],
  ['id-1', [...agents, { ...agents[0], agent: 'id-2', name: 'id-1' }], 'ambiguous_agent'],
]) test(`${code} lists available agents and exits nonzero`, async t => {
  const fake = await server(t, (m, s) => { if (m.type === 'list') s.write(control({ type: 'agents', agents: list })); });
  await assert.rejects(exec(process.execPath, ['packages/cli/main.mjs', 'stream', '--agent', name, '--out', fake.out], { cwd: resolve('.'), env: { ...process.env, OCU_RUNTIME_DIR: fake.directory } }), error => {
    assert.equal(error.code, 1); assert.match(error.stderr, new RegExp(code)); assert.match(error.stderr, /Test agent \(id-1\)/); return true;
  });
  assert.ok(!fake.received.some(m => m.type === 'subscribe'));
});

for (const [type, code, pattern] of [
  ['error', 'unsupported_version', /supports versions: 2, 3/],
  ['error', 'paused', /OCU is stopped/], ['end', 'paused', /OCU is stopped/],
]) test(`${type} ${code} has a clear CLI error`, async t => {
  const fake = await server(t, (m, s) => {
    if (m.type === 'list') s.write(control({ type: 'agents', agents }));
    if (m.type === 'subscribe') s.write(control({ type, code, reason: code, agent: 'id-1', supported: [2, 3] }));
  });
  await assert.rejects(exec(process.execPath, ['packages/cli/main.mjs', 'stream', '--agent', 'id-1', '--out', fake.out], { env: { ...process.env, OCU_RUNTIME_DIR: fake.directory } }), error => {
    assert.equal(error.code, 1); assert.match(error.stderr, pattern); assert.match(error.stdout, /frames: 0; keyframes: 0/); return true;
  });
});

test('every v1 protocol error and end reason is explained', () => {
  for (const code of ['unauthorized', 'unsupported_version', 'unknown_agent', 'paused', 'no_permission', 'codec_unsupported']) {
    const error = streamError({ type: 'error', code }); assert.equal(error.code, code); assert.ok(error.message.length > code.length);
  }
  for (const reason of ['released', 'disconnected', 'stopped', 'paused', 'unsubscribed', 'capture_stopped_by_user', 'error']) {
    const error = streamError({ type: 'end', reason }); assert.equal(error.code, reason); assert.ok(error.message.length > reason.length);
  }
});

test('no frames, broken keyframes and socket EOF fail instead of reporting a valid clip', async t => {
  for (const mode of ['empty', 'missing-format', 'eof']) await t.test(mode, async t => {
    const fake = await server(t, (m, s) => {
      if (m.type === 'list') s.write(control({ type: 'agents', agents }));
      if (m.type === 'subscribe') {
        s.write(target);
        if (mode === 'eof') s.end();
        if (mode === 'missing-format') {
          const header = Buffer.from(JSON.stringify({ agent: 'id-1', codec: 'h264', pts: 1, keyframe: true }));
          const length = Buffer.alloc(4); length.writeUInt32BE(header.length); s.write(frame(2, Buffer.concat([length, header, avcc([0x65])])));
        }
      }
    });
    await assert.rejects(recordStream({ ...fake, agent: 'id-1', seconds: 0.05 }), error => {
      assert.match(error.message, mode === 'empty' ? /No H.264 keyframe/ : mode === 'eof' ? /closed/ : /parameter sets/); return true;
    });
  });
});

test('two simultaneous clients on one agent receive identical fan-out frames', async t => {
  const subscribers = new Set();
  const fake = await server(t, (m, s) => {
    if (m.type === 'list') s.write(control({ type: 'agents', agents }));
    if (m.type === 'subscribe') {
      subscribers.add(s);
      if (subscribers.size === 2) for (const socket of subscribers) socket.write(Buffer.concat([target, video(), video(false, 2)]));
    }
  });
  const outputs = [fake.out, join(fake.directory, 'two.h264')];
  const results = await Promise.all(outputs.map(out => recordStream({ ...fake, out, agent: 'id-1', seconds: 0.15 })));
  assert.deepEqual(results.map(r => r.frames), [2, 2]); assert.deepEqual(await readFile(outputs[0]), await readFile(outputs[1]));
});

test('CLI defaults and validation are explicit; help exposes the command', async () => {
  assert.deepEqual(parseStreamArgs(['--agent', 'a', '--out', 'a.h264']), { agent: 'a', out: 'a.h264', seconds: 5, fps: 15 });
  assert.throws(() => parseStreamArgs([]));
  assert.throws(() => parseStreamArgs(['--agent', 'a']));
  for (const args of [['--fps', '0'], ['--fps', '31'], ['--seconds', '0'], ['--seconds', 'NaN'], ['--seconds', '2147484'], ['--fps', '1.5'], ['--codec', 'hevc']]) {
    assert.throws(() => parseStreamArgs(['--agent', 'a', '--out', 'a.h264', ...args]));
  }
  assert.match((await exec(process.execPath, ['packages/cli/main.mjs', 'help'])).stdout, /stream --agent NAME_OR_ID --out FILE/);
});
