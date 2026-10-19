import test from 'node:test';
import assert from 'node:assert/strict';
import { imageSize, imageTokens, textTokens, callUsage } from '../../packages/host/usage.mjs';
// A JPEG header: SOI, an APP0 segment to skip, then a baseline frame header.
const jpeg = (width, height) => Buffer.concat([Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10]), Buffer.alloc(14),
  Buffer.from([0xff, 0xc0, 0x00, 0x11, 0x08, height >> 8, height & 0xff, width >> 8, width & 0xff, 0x03]), Buffer.alloc(9)]).toString('base64');
const png = (width, height) => { const b = Buffer.alloc(33); b.writeUInt32BE(0x89504e47, 0); b.writeUInt32BE(width, 16); b.writeUInt32BE(height, 20); return b.toString('base64'); };
test('reads image dimensions from JPEG and PNG headers', () => {
  assert.deepEqual(imageSize(jpeg(1440, 900)), { width: 1440, height: 900 });
  assert.deepEqual(imageSize(png(800, 600)), { width: 800, height: 600 });
  assert.equal(imageSize(Buffer.from('not an image').toString('base64')), null);
});
test('image tokens follow the resize limits', () => {
  assert.equal(imageTokens(1000, 750), 1000);
  // A 5K window is scaled to 2576 px on the long edge, then to 3.75 MP.
  assert.ok(imageTokens(5120, 2880) <= 3_750_000 / 750);
  assert.equal(imageTokens(0, 10), 0);
});
test('a call counts its arguments as output and its result as input', () => {
  const usage = callUsage({ app_target: 'Notes' }, { content: [{ type: 'text', text: 'x'.repeat(400) }, { type: 'image', data: jpeg(1000, 750), mimeType: 'image/jpeg' }] });
  assert.deepEqual(usage, { calls: 1, images: 1, input_tokens: 1100, output_tokens: textTokens('{"app_target":"Notes"}') });
  assert.equal(callUsage({}, undefined, { code: 'busy', message: 'x'.repeat(10) }).input_tokens, textTokens('busy: xxxxxxxxxx'));
});
