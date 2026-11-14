import { createHash } from 'node:crypto';
import { baseDecode } from 'near-api-js';
import { adaOk, bchOk, btcOk, dogeOk, ltcOk, suiOk, tonOk, xrpOk } from './addresses.ts';
import { checksumOk } from './eip55.ts';

/** One row of 1Click GET /v0/tokens. */
export type TokenRow = { assetId: string; decimals: number; blockchain: string; symbol: string; price: number | string; contractAddress?: string; coingeckoId?: string };

type AddressKind = 'evm' | 'sol' | 'tron' | 'near' | 'btc' | 'ltc' | 'doge' | 'bch' | 'xrp' | 'ada' | 'sui' | 'ton';
/** Destination chains Pip pays to. `id` is 1Click's blockchain name; `relayChainId` lets Relay price the destination asset. */
export const CHAINS: Record<string, { name: string; kind: AddressKind; aliases: string[]; relayChainId?: number }> = {
  near: { name: 'NEAR', kind: 'near', aliases: ['near'] },
  eth: { name: 'Ethereum', kind: 'evm', aliases: ['eth', 'ethereum', 'mainnet'], relayChainId: 1 },
  base: { name: 'Base', kind: 'evm', aliases: ['base'], relayChainId: 8453 },
  arb: { name: 'Arbitrum', kind: 'evm', aliases: ['arb', 'arbitrum'], relayChainId: 42161 },
  op: { name: 'Optimism', kind: 'evm', aliases: ['op', 'optimism'], relayChainId: 10 },
  pol: { name: 'Polygon', kind: 'evm', aliases: ['pol', 'polygon', 'matic'], relayChainId: 137 },
  avax: { name: 'Avalanche', kind: 'evm', aliases: ['avax', 'avalanche'], relayChainId: 43114 },
  bsc: { name: 'BNB Chain', kind: 'evm', aliases: ['bsc', 'bnb', 'binance'], relayChainId: 56 },
  gnosis: { name: 'Gnosis', kind: 'evm', aliases: ['gnosis', 'xdai'], relayChainId: 100 },
  sol: { name: 'Solana', kind: 'sol', aliases: ['sol', 'solana'], relayChainId: 792703809 },
  tron: { name: 'Tron', kind: 'tron', aliases: ['tron', 'trx'] },
  btc: { name: 'Bitcoin', kind: 'btc', aliases: ['btc', 'bitcoin'] },
  ltc: { name: 'Litecoin', kind: 'ltc', aliases: ['ltc', 'litecoin'] },
  bch: { name: 'Bitcoin Cash', kind: 'bch', aliases: ['bch', 'bitcoincash'] },
  doge: { name: 'Dogecoin', kind: 'doge', aliases: ['doge', 'dogecoin'] },
  xrp: { name: 'XRP Ledger', kind: 'xrp', aliases: ['xrp', 'xrpl', 'ripple'] },
  cardano: { name: 'Cardano', kind: 'ada', aliases: ['cardano', 'ada'] },
  sui: { name: 'Sui', kind: 'sui', aliases: ['sui'] },
  ton: { name: 'TON', kind: 'ton', aliases: ['ton'] },
};

export function chainByName(raw: string): string | null {
  const n = raw.toLowerCase();
  return Object.keys(CHAINS).find((id) => CHAINS[id].aliases.includes(n)) ?? null;
}

/** What Pip can spend from the user's NEAR account. NEAR is wrapped to wNEAR in the same transaction. */
export const ORIGINS: Record<'NEAR' | 'USDC' | 'USDT', { assetId: string; contract: string; wrap: boolean }> = {
  NEAR: { assetId: 'nep141:wrap.near', contract: 'wrap.near', wrap: true },
  USDC: { assetId: 'nep141:17208628f84f5d6ad33f0da3bbbeb27ffcb398eac501a31bd6ad2011e36133a1', contract: '17208628f84f5d6ad33f0da3bbbeb27ffcb398eac501a31bd6ad2011e36133a1', wrap: false },
  USDT: { assetId: 'nep141:usdt.tether-token.near', contract: 'usdt.tether-token.near', wrap: false },
};
export type Origin = keyof typeof ORIGINS;

const B58 = /^[1-9A-HJ-NP-Za-km-z]+$/;
const NEAR_ID = /^(?=.{2,64}$)(([a-z\d]+[-_])*[a-z\d]+\.)*([a-z\d]+[-_])*[a-z\d]+$/;

const VALID: Record<AddressKind, (a: string) => boolean> = {
  evm: (a) => /^0x[0-9a-fA-F]{40}$/.test(a), sui: suiOk, tron: (a) => tronOk(a), btc: btcOk, ltc: ltcOk, doge: dogeOk, bch: bchOk,
  xrp: xrpOk, ada: adaOk, ton: tonOk, sol: (a) => solOk(a), near: (a) => nearOk(a),
};

/** The chain an address belongs to, 'ambiguous' when several fit (a "3…" address is both Bitcoin and Litecoin), or null. */
export function addressChain(a: string): string | 'ambiguous' | null {
  const kinds = (Object.keys(VALID) as AddressKind[]).filter((k) => VALID[k](a));
  const chains = [...new Set(kinds.map((k) => (k === 'evm' ? 'evm' : Object.keys(CHAINS).find((id) => CHAINS[id].kind === k)!)))];
  if (chains.length === 0) return null;
  return chains.length > 1 ? 'ambiguous' : chains[0];
}

function solOk(a: string) {
  if (a.length < 32 || a.length > 44 || !B58.test(a)) return false;
  try {
    return baseDecode(a).length === 32;
  } catch {
    return false;
  }
}
/** Base58check: 25 bytes, first 0x41, last 4 = sha256(sha256(first 21)). */
function tronOk(a: string) {
  if (!/^T[1-9A-HJ-NP-Za-km-z]{33}$/.test(a)) return false;
  let b: Uint8Array;
  try {
    b = baseDecode(a);
  } catch {
    return false;
  }
  if (b.length !== 25 || b[0] !== 0x41) return false;
  const h = createHash('sha256').update(createHash('sha256').update(b.subarray(0, 21)).digest()).digest();
  return h.subarray(0, 4).equals(Buffer.from(b.subarray(21)));
}
/** Mainnet NEAR: implicit (64 hex) or a named .near account. */
const nearOk = (a: string) => NEAR_ID.test(a) && (/^[0-9a-f]{64}$/.test(a) || a.endsWith('.near'));

/** Checks an address against the chain's format. A mixed-case EVM address must pass EIP-55. */
export function checkAddress(chain: string, a: string): { ok: true } | { ok: false; reason: string } {
  const c = CHAINS[chain];
  if (!c) return { ok: false, reason: `Pip does not pay to ${chain} yet` };
  if (c.kind === 'evm' && /^0x[0-9a-fA-F]{40}$/.test(a) && !checksumOk(a)) return { ok: false, reason: 'the address checksum is wrong; check the capital letters' };
  const ok = c.kind === 'evm' ? VALID.evm(a) && !/^0x0{40}$/.test(a) : VALID[c.kind](a);
  return ok ? { ok: true } : { ok: false, reason: `not a ${c.name} address` };
}

/** The one token row for a symbol on a chain. Refuses when the list has none or more than one (never guesses). */
export function findToken(list: TokenRow[], symbol: string, chain: string): { ok: true; token: TokenRow } | { ok: false; reason: string } {
  const s = symbol.toUpperCase();
  const rows = list.filter((t) => t.blockchain === chain && t.symbol.toUpperCase() === s);
  if (rows.length === 0) return { ok: false, reason: `${s} on ${CHAINS[chain]?.name ?? chain} is not supported` };
  if (rows.length > 1) return { ok: false, reason: `${s} on ${CHAINS[chain]?.name ?? chain} is ambiguous` };
  const t = rows[0];
  if (!Number.isInteger(t.decimals) || t.decimals < 0 || t.decimals > 30) return { ok: false, reason: `bad decimals for ${s}` };
  return { ok: true, token: t };
}

/** The token row for an origin asset, by its fixed asset id. */
export function findOrigin(list: TokenRow[], origin: Origin): TokenRow | null {
  return list.find((t) => t.assetId === ORIGINS[origin].assetId) ?? null;
}
