import { createHash } from 'node:crypto';
import { baseDecode } from 'near-api-js';

/** One row of 1Click GET /v0/tokens. */
export type TokenRow = { assetId: string; decimals: number; blockchain: string; symbol: string; price: number | string; contractAddress?: string; coingeckoId?: string };

type AddressKind = 'evm' | 'sol' | 'tron' | 'near';
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

/** Which address kind a string looks like, or null. Used to infer the chain when the text names none. */
export function addressKind(a: string): AddressKind | null {
  if (/^0x[0-9a-fA-F]{40}$/.test(a)) return 'evm';
  if (tronOk(a)) return 'tron';
  if (solOk(a)) return 'sol';
  if (nearOk(a)) return 'near';
  return null;
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

/** Checks an address against the chain's format. EVM checksums are not verified (mixed case is taken as typed). */
export function checkAddress(chain: string, a: string): { ok: true } | { ok: false; reason: string } {
  const c = CHAINS[chain];
  if (!c) return { ok: false, reason: `Pip does not pay to ${chain} yet` };
  const ok = c.kind === 'evm' ? /^0x[0-9a-fA-F]{40}$/.test(a) && !/^0x0{40}$/.test(a) : c.kind === 'sol' ? solOk(a) : c.kind === 'tron' ? tronOk(a) : nearOk(a);
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

const RELAY_NATIVE: Record<string, string> = { sol: '11111111111111111111111111111111' };
/** Canonical Relay assets for coins that also live on NEAR, by CoinGecko id, so Relay can price an origin asset too. */
const RELAY_BY_COINGECKO: Record<string, { chainId: number; address: string }> = {
  'usd-coin': { chainId: 1, address: '0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48' },
  tether: { chainId: 1, address: '0xdac17f958d2ee523a2206206994597c13d831ec7' },
  ethereum: { chainId: 1, address: '0x0000000000000000000000000000000000000000' },
};

/** Where Relay prices this token, or null (Relay has no NEAR chain, so NEAR-only coins have no Relay price). */
export function relayAsset(t: TokenRow): { chainId: number; address: string } | null {
  const c = CHAINS[t.blockchain];
  if (c?.relayChainId && t.blockchain !== 'near') {
    const address = t.contractAddress ?? (c.kind === 'evm' ? '0x0000000000000000000000000000000000000000' : RELAY_NATIVE[t.blockchain]);
    if (address) return { chainId: c.relayChainId, address };
  }
  return (t.coingeckoId && RELAY_BY_COINGECKO[t.coingeckoId]) || null;
}
