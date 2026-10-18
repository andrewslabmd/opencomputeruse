import { homedir } from 'node:os';
import { join } from 'node:path';
export const VERSION = 1;
export const MAX_FRAME = 8 * 1024 * 1024;
export const runtimeDirectory = () => process.env.OCU_RUNTIME_DIR || join(homedir(), 'Library', 'Application Support', 'Open Computer Use');
export const failure = (code, message) => Object.assign(new Error(message), { code });
export function frameReader(onFrame, onError) {
  let buffer = '';
  return chunk => {
    buffer += chunk;
    if (Buffer.byteLength(buffer) > MAX_FRAME) { buffer = ''; onError(failure('frame_too_large', 'Frame limit exceeded')); return; }
    let end;
    while ((end = buffer.indexOf('\n')) >= 0) {
      const line = buffer.slice(0, end); buffer = buffer.slice(end + 1);
      if (!line.trim()) continue;
      try { onFrame(JSON.parse(line)); } catch { onError(failure('invalid_json', 'Invalid JSON frame')); }
    }
  };
}
