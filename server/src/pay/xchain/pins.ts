import type { TokenRow } from './assets.ts';

/**
 * Pip's own record of each asset it verifies, keyed by (chain, contract). Price lookups use these ids and addresses,
 * never 1Click's row, and a row that disagrees with its pin is refused. An unpinned asset is never verified.
 */
export type Pin = { symbol: string; decimals: number; coingeckoId: string; relay: { chainId: number; address: string } | null };

const ZERO = '0x0000000000000000000000000000000000000000';
const ETH_USDC = { chainId: 1, address: '0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48' };
const ETH_USDT = { chainId: 1, address: '0xdac17f958d2ee523a2206206994597c13d831ec7' };

const PINS: Record<string, Pin> = {
  // NEAR: Relay has no NEAR chain, so stablecoins are priced through their Ethereum twin; wNEAR has CoinGecko only.
  'near:17208628f84f5d6ad33f0da3bbbeb27ffcb398eac501a31bd6ad2011e36133a1': { symbol: 'USDC', decimals: 6, coingeckoId: 'usd-coin', relay: ETH_USDC },
  'near:usdt.tether-token.near': { symbol: 'USDT', decimals: 6, coingeckoId: 'tether', relay: ETH_USDT },
  'near:wrap.near': { symbol: 'WNEAR', decimals: 24, coingeckoId: 'wrapped-near', relay: null },
  'eth:0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48': { symbol: 'USDC', decimals: 6, coingeckoId: 'usd-coin', relay: ETH_USDC },
  'eth:0xdac17f958d2ee523a2206206994597c13d831ec7': { symbol: 'USDT', decimals: 6, coingeckoId: 'tether', relay: ETH_USDT },
  'eth:native': { symbol: 'ETH', decimals: 18, coingeckoId: 'ethereum', relay: { chainId: 1, address: ZERO } },
  'base:0x833589fcd6edb6e08f4c7c32d4f71b54bda02913': { symbol: 'USDC', decimals: 6, coingeckoId: 'usd-coin', relay: { chainId: 8453, address: '0x833589fcd6edb6e08f4c7c32d4f71b54bda02913' } },
  'base:native': { symbol: 'ETH', decimals: 18, coingeckoId: 'ethereum', relay: { chainId: 8453, address: ZERO } },
  'arb:0xaf88d065e77c8cc2239327c5edb3a432268e5831': { symbol: 'USDC', decimals: 6, coingeckoId: 'usd-coin', relay: { chainId: 42161, address: '0xaf88d065e77c8cc2239327c5edb3a432268e5831' } },
  'arb:0xfd086bc7cd5c481dcc9c85ebe478a1c0b69fcbb9': { symbol: 'USDT', decimals: 6, coingeckoId: 'tether', relay: { chainId: 42161, address: '0xfd086bc7cd5c481dcc9c85ebe478a1c0b69fcbb9' } },
  'arb:native': { symbol: 'ETH', decimals: 18, coingeckoId: 'ethereum', relay: { chainId: 42161, address: ZERO } },
  'sol:EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v': { symbol: 'USDC', decimals: 6, coingeckoId: 'usd-coin', relay: { chainId: 792703809, address: 'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v' } },
  'sol:Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB': { symbol: 'USDT', decimals: 6, coingeckoId: 'tether', relay: { chainId: 792703809, address: 'Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB' } },
  'sol:native': { symbol: 'SOL', decimals: 9, coingeckoId: 'solana', relay: { chainId: 792703809, address: '11111111111111111111111111111111' } },
  'bsc:0x8ac76a51cc950d9822d68b83fe1ad97b32cd580d': { symbol: 'USDC', decimals: 18, coingeckoId: 'usd-coin', relay: { chainId: 56, address: '0x8ac76a51cc950d9822d68b83fe1ad97b32cd580d' } },
  'bsc:0x55d398326f99059ff775485246999027b3197955': { symbol: 'USDT', decimals: 18, coingeckoId: 'tether', relay: { chainId: 56, address: '0x55d398326f99059ff775485246999027b3197955' } },
  'tron:TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t': { symbol: 'USDT', decimals: 6, coingeckoId: 'tether', relay: ETH_USDT },
  'pol:0x3c499c542cef5e3811e1192ce70d8cc03d5c3359': { symbol: 'USDC', decimals: 6, coingeckoId: 'usd-coin', relay: { chainId: 137, address: '0x3c499c542cef5e3811e1192ce70d8cc03d5c3359' } },
  'pol:0xc2132d05d31c914a87c6611c10748aeb04b58e8f': { symbol: 'USDT', decimals: 6, coingeckoId: 'tether', relay: { chainId: 137, address: '0xc2132d05d31c914a87c6611c10748aeb04b58e8f' } },
  // Pip does not pay to Bitcoin yet (no address check); the pin is kept so BTC numbers are ready when it does.
  'btc:native': { symbol: 'BTC', decimals: 8, coingeckoId: 'bitcoin', relay: null },
};

const key = (t: Pick<TokenRow, 'blockchain' | 'contractAddress'>) => {
  const c = t.contractAddress;
  if (!c) return `${t.blockchain}:native`;
  return `${t.blockchain}:${/^0x[0-9a-fA-F]{40}$/.test(c) ? c.toLowerCase() : c}`;
};

/** The pin for a 1Click row, checked against it: refused on any disagreement, unpinned when Pip has no record. */
export function checkPin(t: TokenRow): { ok: true; pin: Pin } | { ok: false; refused: string | null; reason: string } {
  const pin = PINS[key(t)];
  const name = `${t.symbol} on ${t.blockchain}`;
  if (!pin) return { ok: false, refused: null, reason: `${name} is not on Pip's pinned list` };
  const bad = (what: string, row: unknown, ours: unknown) => ({ ok: false as const, refused: `1Click's ${name} ${what} (${row}) differs from Pip's pin (${ours})`, reason: '' });
  if (t.symbol.toUpperCase() !== pin.symbol) return bad('symbol', t.symbol, pin.symbol);
  if (t.decimals !== pin.decimals) return bad('decimals', t.decimals, pin.decimals);
  if (t.coingeckoId !== undefined && t.coingeckoId !== pin.coingeckoId) return bad('CoinGecko id', t.coingeckoId, pin.coingeckoId);
  return { ok: true, pin };
}
