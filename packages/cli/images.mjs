import { mkdtemp, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

// Images are written to files instead of printed as base64. Screenshots can
// hold private content: the default is a new owner-only temporary directory.
export async function saveImages(result, file) {
  const images = (result?.content ?? []).filter(item => item?.type === 'image' && typeof item.data === 'string');
  if (!images.length) return result;
  const directory = file ? undefined : await mkdtemp(join(tmpdir(), 'ocu-screenshot-'));
  const content = [];
  let index = 0;
  for (const item of result.content) {
    if (!images.includes(item)) { content.push(item); continue; }
    const suffix = index ? `-${index}` : '';
    const path = file ? resolve(file.replace(/(\.[^./]+)?$/, `${suffix}$1`))
      : join(directory, `observe${suffix}.${item.mimeType === 'image/png' ? 'png' : 'jpg'}`);
    await writeFile(path, Buffer.from(item.data, 'base64'), { mode: 0o600 });
    content.push({ type: 'image', ...(item.mimeType ? { mimeType: item.mimeType } : {}), saved_to: path });
    index += 1;
  }
  return { ...result, content };
}
