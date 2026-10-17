import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { saveImages } from '../../packages/cli/images.mjs';

const image = data => ({ type: 'image', mimeType: 'image/jpeg', data: Buffer.from(data).toString('base64') });

test('observe --screenshot writes images to owner-only files and prints their paths, not base64', async () => {
  const text = { type: 'text', text: 'status: observed' };
  const result = await saveImages({ content: [text, image('jpeg-bytes')] });
  assert.deepEqual(result.content[0], text);
  const saved = result.content[1];
  assert.equal(saved.data, undefined); assert.equal(saved.type, 'image'); assert.match(saved.saved_to, /ocu-screenshot-.*\/observe\.jpg$/);
  assert.equal(await readFile(saved.saved_to, 'utf8'), 'jpeg-bytes');
  assert.equal((await stat(saved.saved_to)).mode & 0o777, 0o600);
});

test('an explicit screenshot path is used, numbered for further images; no image leaves the result unchanged', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'ocu-cli-test-'));
  const result = await saveImages({ content: [image('one'), image('two')] }, join(directory, 'phone.jpg'));
  assert.deepEqual(result.content.map(item => item.saved_to), [join(directory, 'phone.jpg'), join(directory, 'phone-1.jpg')]);
  assert.equal(await readFile(join(directory, 'phone-1.jpg'), 'utf8'), 'two');
  const plain = { content: [{ type: 'text', text: 'screenshot_error: x' }] };
  assert.equal(await saveImages(plain, join(directory, 'none.jpg')), plain);
});
