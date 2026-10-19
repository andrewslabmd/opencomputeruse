// Estimated tokens an agent spends on Open Computer Use. The host never sees
// the model's own usage: it counts only what crosses MCP. Arguments the agent
// writes are its output; results it reads (text and screenshots) its input.
// Text is about 4 characters per token. Images follow Claude's current vision
// rules: scaled to 2576 px on the long edge and 3.75 MP, then (w × h) / 750.
const CHARS_PER_TOKEN = 4, LONG_EDGE = 2576, MAX_PIXELS = 3_750_000, PIXELS_PER_TOKEN = 750;

export const emptyUsage = () => ({ calls: 0, images: 0, input_tokens: 0, output_tokens: 0 });
export function addUsage(total, part) { for (const key of Object.keys(total)) total[key] += part[key] ?? 0; }

export function textTokens(text) { return Math.ceil(String(text ?? '').length / CHARS_PER_TOKEN); }

export function imageTokens(width, height) {
  if (!(width > 0 && height > 0)) return 0;
  const scale = Math.min(1, LONG_EDGE / Math.max(width, height), Math.sqrt(MAX_PIXELS / (width * height)));
  return Math.ceil(Math.round(width * scale) * Math.round(height * scale) / PIXELS_PER_TOKEN);
}

// Width and height from a JPEG's frame header or a PNG's IHDR, or null.
export function imageSize(data) {
  // The header sits near the start; decoding the whole image is not needed.
  const bytes = Buffer.from(String(data ?? '').slice(0, 262_144), 'base64');
  if (bytes.length > 24 && bytes.readUInt32BE(0) === 0x89504e47) return { width: bytes.readUInt32BE(16), height: bytes.readUInt32BE(20) };
  if (bytes[0] !== 0xff || bytes[1] !== 0xd8) return null;
  for (let i = 2; i + 9 < bytes.length;) {
    if (bytes[i] !== 0xff) return null;
    const marker = bytes[i + 1];
    if (marker === 0xff) { i++; continue; }
    // Start of frame: any SOFn except DHT (c4), JPG (c8) and DAC (cc).
    if (marker >= 0xc0 && marker <= 0xcf && ![0xc4, 0xc8, 0xcc].includes(marker)) return { width: bytes.readUInt16BE(i + 7), height: bytes.readUInt16BE(i + 5) };
    i += 2 + bytes.readUInt16BE(i + 2);
  }
  return null;
}

// One tool call: its arguments, and its result or the error text the agent reads instead.
export function callUsage(args, result, error) {
  const usage = { ...emptyUsage(), calls: 1, output_tokens: textTokens(JSON.stringify(args ?? {})) };
  if (error) { usage.input_tokens = textTokens(`${error.code || 'error'}: ${error.message}`); return usage; }
  for (const block of result?.content ?? []) {
    if (block?.type === 'image') {
      const size = imageSize(block.data);
      usage.images++; usage.input_tokens += size ? imageTokens(size.width, size.height) : 0;
    } else usage.input_tokens += textTokens(block?.type === 'text' ? block.text : JSON.stringify(block));
  }
  return usage;
}
