import { createHash } from 'node:crypto';
import { baseDecode } from 'near-api-js';

/** Address checks for non-EVM, non-NEAR destination chains. Each one checks the checksum; none guesses. */

const sha256 = (b: Uint8Array) => createHash('sha256').update(b).digest();
const BTC58 = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';
const XRP58 = 'rpshnaf39wBUDNEGHJKLM4PQRST7VWXYZ2bcdeCg65jkm8oFqi1tuvAxyz';

/** Base58check payload (version byte included), or null when the alphabet or checksum is wrong. */
export function base58check(s: string, alphabet = BTC58): Uint8Array | null {
  if (!s || [...s].some((ch) => !alphabet.includes(ch))) return null;
  const asBtc = alphabet === BTC58 ? s : [...s].map((ch) => BTC58[alphabet.indexOf(ch)]).join('');
  let b: Uint8Array;
  try {
    b = baseDecode(asBtc);
  } catch {
    return null;
  }
  if (b.length < 5) return null;
  const body = b.subarray(0, -4);
  return sha256(sha256(body)).subarray(0, 4).equals(Buffer.from(b.subarray(-4))) ? body : null;
}

const CHARSET = 'qpzry9x8gf2tvdw0s3jn54khce6mua7l';
function polymod(values: number[]): number {
  const G = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3];
  let chk = 1;
  for (const v of values) {
    const top = chk >>> 25;
    chk = ((chk & 0x1ffffff) << 5) ^ v;
    for (let i = 0; i < 5; i++) if ((top >>> i) & 1) chk ^= G[i];
  }
  return chk >>> 0;
}
const hrpExpand = (hrp: string) => [...[...hrp].map((c) => c.charCodeAt(0) >> 5), 0, ...[...hrp].map((c) => c.charCodeAt(0) & 31)];

/** Bech32 / bech32m (BIP-173, BIP-350). No 90-char limit, since Cardano addresses are longer. */
export function bech32Decode(s: string): { hrp: string; data: number[]; spec: 'bech32' | 'bech32m' } | null {
  if (s !== s.toLowerCase() && s !== s.toUpperCase()) return null;
  const str = s.toLowerCase();
  const pos = str.lastIndexOf('1');
  if (pos < 1 || pos + 7 > str.length) return null;
  const hrp = str.slice(0, pos);
  const data = [...str.slice(pos + 1)].map((c) => CHARSET.indexOf(c));
  if (data.some((d) => d < 0)) return null;
  const pm = polymod([...hrpExpand(hrp), ...data]);
  const spec = pm === 1 ? 'bech32' : pm === 0x2bc830a3 ? 'bech32m' : null;
  return spec ? { hrp, data: data.slice(0, -6), spec } : null;
}

export function convertBits(data: number[], from: number, to: number, pad: boolean): number[] | null {
  let acc = 0, bits = 0;
  const out: number[] = [], max = (1 << to) - 1;
  for (const v of data) {
    acc = (acc << from) | v;
    bits += from;
    while (bits >= to) {
      bits -= to;
      out.push((acc >> bits) & max);
    }
  }
  if (pad) {
    if (bits > 0) out.push((acc << (to - bits)) & max);
  } else if (bits >= from || ((acc << (to - bits)) & max)) return null;
  return out;
}

/** A segwit address for `hrp` (bc, ltc): v0 is bech32 with a 20/32-byte program, v1+ is bech32m. */
function segwitOk(s: string, hrp: string) {
  const d = bech32Decode(s);
  if (!d || d.hrp !== hrp || d.data.length < 1) return false;
  const v = d.data[0];
  const prog = convertBits(d.data.slice(1), 5, 8, false);
  if (!prog || v > 16 || prog.length < 2 || prog.length > 40) return false;
  if (v === 0) return d.spec === 'bech32' && (prog.length === 20 || prog.length === 32);
  return d.spec === 'bech32m';
}
const legacyOk = (s: string, versions: number[]) => {
  const p = base58check(s);
  return !!p && p.length === 21 && versions.includes(p[0]);
};

export const btcOk = (s: string) => legacyOk(s, [0x00, 0x05]) || segwitOk(s, 'bc');
export const ltcOk = (s: string) => legacyOk(s, [0x30, 0x32, 0x05]) || segwitOk(s, 'ltc');
export const dogeOk = (s: string) => legacyOk(s, [0x1e, 0x16]);
/** XRP classic address: Ripple's base58 alphabet, version 0, 20-byte account id. */
export const xrpOk = (s: string) => {
  const p = /^r[1-9A-HJ-NP-Za-km-z]{24,34}$/.test(s) ? base58check(s, XRP58) : null;
  return !!p && p.length === 21 && p[0] === 0x00;
};

/** CashAddr (bitcoincash:q… / p…), 20-byte hash. The prefix may be left out. */
export function bchOk(s: string) {
  const lower = s.toLowerCase();
  if (s !== lower && s !== s.toUpperCase()) return false;
  const [prefix, payload] = lower.includes(':') ? lower.split(':') : ['bitcoincash', lower];
  if (prefix !== 'bitcoincash' || !/^[qp][qpzry9x8gf2tvdw0s3jn54khce6mua7l]{41}$/.test(payload)) return false;
  const data = [...payload].map((c) => CHARSET.indexOf(c));
  const G = [0x98f2bc8e61n, 0x79b76d99e2n, 0xf33e5fb3c4n, 0xae2eabe2a8n, 0x1e4f43e470n];
  let c = 1n;
  for (const v of [...[...prefix].map((ch) => ch.charCodeAt(0) & 31), 0, ...data]) {
    const c0 = c >> 35n;
    c = ((c & 0x07ffffffffn) << 5n) ^ BigInt(v);
    for (let i = 0; i < 5; i++) if ((c0 >> BigInt(i)) & 1n) c ^= G[i];
  }
  if ((c ^ 1n) !== 0n) return false;
  const bytes = convertBits(data.slice(0, -8), 5, 8, false);
  return !!bytes && bytes.length === 21 && (bytes[0] === 0x00 || bytes[0] === 0x08);
}

/** Cardano Shelley mainnet (bech32 "addr", network id 1). Byron addresses are refused. */
export function adaOk(s: string) {
  const d = bech32Decode(s);
  if (!d || d.hrp !== 'addr') return false;
  const bytes = convertBits(d.data, 5, 8, false);
  return !!bytes && bytes.length >= 29 && (bytes[0] & 0x0f) === 1 && bytes[0] >> 4 <= 7;
}

export const suiOk = (s: string) => /^0x[0-9a-fA-F]{64}$/.test(s);

/** TON: raw "0:<64 hex>" or the 48-char friendly form with its CRC16; testnet-only addresses are refused. */
export function tonOk(s: string) {
  if (/^(0|-1):[0-9a-fA-F]{64}$/.test(s)) return true;
  if (!/^[A-Za-z0-9_+/-]{48}$/.test(s)) return false;
  const b = Buffer.from(s.replace(/-/g, '+').replace(/_/g, '/'), 'base64');
  if (b.length !== 36 || ![0x11, 0x51].includes(b[0]) || ![0x00, 0xff].includes(b[1])) return false;
  let crc = 0;
  for (const byte of b.subarray(0, 34)) {
    crc ^= byte << 8;
    for (let i = 0; i < 8; i++) crc = crc & 0x8000 ? ((crc << 1) ^ 0x1021) & 0xffff : (crc << 1) & 0xffff;
  }
  return crc === b.readUInt16BE(34);
}
