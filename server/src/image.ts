// Reads the size of a PNG or JPEG from its header bytes. Undefined when the bytes are not that kind of image.
export type Size = { width: number; height: number };

const PNG_MAGIC = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];

export const isPng = (b: Uint8Array) => b.length >= PNG_MAGIC.length && PNG_MAGIC.every((v, i) => b[i] === v);

export function pngSize(b: Uint8Array): Size | undefined {
  // The first chunk is IHDR: width and height are its first 8 bytes.
  if (!isPng(b) || b.length < 24 || String.fromCharCode(...b.subarray(12, 16)) !== 'IHDR') return undefined;
  const v = new DataView(b.buffer, b.byteOffset, b.byteLength);
  const width = v.getUint32(16), height = v.getUint32(20);
  return width && height ? { width, height } : undefined;
}

export function jpegSize(b: Uint8Array): Size | undefined {
  if (b.length < 4 || b[0] !== 0xff || b[1] !== 0xd8 || b[2] !== 0xff) return undefined;
  // Walk the marker segments to the first start-of-frame (SOF0-SOF15, but not DHT C4, JPG C8 or DAC CC).
  let i = 2;
  while (i + 9 < b.length) {
    if (b[i] !== 0xff) return undefined;
    const marker = b[i + 1];
    if (marker === 0xff) { i++; continue; }
    const len = (b[i + 2] << 8) | b[i + 3];
    if (marker >= 0xc0 && marker <= 0xcf && ![0xc4, 0xc8, 0xcc].includes(marker)) {
      const height = (b[i + 5] << 8) | b[i + 6], width = (b[i + 7] << 8) | b[i + 8];
      return width && height ? { width, height } : undefined;
    }
    if (marker === 0xda || len < 2) return undefined;
    i += 2 + len;
  }
  return undefined;
}
