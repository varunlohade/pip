const ch = (code: number) => String.fromCodePoint(code);
const range = (from: number, to: number) => `${ch(from)}-${ch(to)}`;
// Invisible characters: all format chars (Cf: bidi marks, zero-width, soft hyphen, BOM, tags) plus
// zero-width / invisible operators, variation selectors and the whole Unicode Tag block, listed explicitly.
const INVISIBLE = new RegExp(
  `[\\p{Cf}${ch(0xad)}${range(0x200b, 0x200f)}${range(0x2060, 0x2064)}${ch(0xfeff)}${range(0xfe00, 0xfe0f)}${range(0xe0000, 0xe007f)}]`,
  'gu',
);
// C0 and C1 controls (newlines, tabs included) plus the Unicode line and paragraph separators.
const CONTROL = new RegExp(`[${range(0x00, 0x1f)}${range(0x7f, 0x9f)}${ch(0x2028)}${ch(0x2029)}]`, 'g');

export const clean = (s: string) =>
  s.normalize('NFKC').replace(INVISIBLE, '').replace(CONTROL, ' ').replace(/\s+/g, ' ').trim();
