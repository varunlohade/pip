import { test } from 'node:test';
import assert from 'node:assert/strict';
import { clean } from '../src/text.ts';

const cp = (...codes: number[]) => String.fromCodePoint(...codes);

test('F2: clean() strips zero-width, format, variation and tag characters after NFKC', () => {
  const dirty = `Ha${cp(0x200b)}ir${cp(0xad)}c${cp(0x2060)}u${cp(0xfeff)}t${cp(0xfe0f)}${cp(0xe0001, 0xe0069, 0xe0067, 0xe006e)}${cp(0x2063)} ${cp(0xff11)}`;
  assert.equal(clean(dirty), 'Haircut 1');
  assert.equal(clean(`a${cp(0x200d)}b${cp(0x180e)}c`), 'abc');
});
