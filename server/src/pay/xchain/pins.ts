import type { TokenRow } from './assets.ts';

/**
 * Pip's own record of each asset it verifies, keyed by (chain, contract). Price lookups use these ids and addresses,
 * never 1Click's row, and a row that disagrees with its pin is refused. An unpinned or unverified asset is never verified.
 *
 * Generated 2026-11-14 from read-only calls: the 1Click token list, CoinGecko /coins/list?include_platform=true
 * (contract -> id; natives from a fixed chain table), and each token's decimals read on its own chain
 * (EVM decimals(), NEAR ft_metadata, Solana mint, Tron TRC-20, Sui coinMetadata). The table is in docs/XCHAIN-NUMBERS.md.
 * `oneclickCoingeckoId` records 1Click's own id when it differs (bridged tokens); the pin's CoinGecko id is the one used.
 */
export type Pin = {
  symbol: string; decimals: number; decimalsSource: string; coingeckoId: string | null; oneclickCoingeckoId?: string;
  relay: { chainId: number; address: string } | null; unverified?: string;
};

/** A pin that passed checkPin: it has a CoinGecko id and verified decimals. */
export type VerifiedPin = Pin & { coingeckoId: string };

export const PINS: Record<string, Pin> = {
  'eth:0x7fc66500c84a76ad7e9c93437bfc5ac33e2ddae9': { symbol: 'AAVE', decimals: 18, decimalsSource: 'decimals()', coingeckoId: 'aave', relay: { chainId: 1, address: '0x7fc66500c84a76ad7e9c93437bfc5ac33e2ddae9' } },
  'cardano:native': { symbol: 'ADA', decimals: 6, decimalsSource: 'native constant', coingeckoId: 'cardano', relay: null },
  'arb:0x912ce59144191c1204e64559fe8253a0e49e6548': { symbol: 'ARB', decimals: 18, decimalsSource: 'decimals()', coingeckoId: 'arbitrum', relay: { chainId: 42161, address: '0x912ce59144191c1204e64559fe8253a0e49e6548' } },
  'avax:native': { symbol: 'AVAX', decimals: 18, decimalsSource: 'native constant', coingeckoId: 'avalanche-2', relay: { chainId: 43114, address: '0x0000000000000000000000000000000000000000' } },
  'bch:native': { symbol: 'BCH', decimals: 8, decimalsSource: 'native constant', coingeckoId: 'bitcoin-cash', relay: null },
  'bsc:native': { symbol: 'BNB', decimals: 18, decimalsSource: 'native constant', coingeckoId: 'binancecoin', relay: { chainId: 56, address: '0x0000000000000000000000000000000000000000' } },
  'btc:native': { symbol: 'BTC', decimals: 8, decimalsSource: 'native constant', coingeckoId: 'bitcoin', relay: null },
  'near:nbtc.bridge.near': { symbol: 'BTC', decimals: 8, decimalsSource: 'ft_metadata', coingeckoId: 'near-intents-bridged-wbtc', oneclickCoingeckoId: 'bitcoin', relay: null },
  'eth:0x6b175474e89094c44da98b954eedeac495271d0f': { symbol: 'DAI', decimals: 18, decimalsSource: 'decimals()', coingeckoId: 'dai', relay: { chainId: 1, address: '0x6b175474e89094c44da98b954eedeac495271d0f' } },
  'doge:native': { symbol: 'DOGE', decimals: 8, decimalsSource: 'native constant', coingeckoId: 'dogecoin', relay: null },
  'arb:native': { symbol: 'ETH', decimals: 18, decimalsSource: 'native constant', coingeckoId: 'ethereum', relay: { chainId: 42161, address: '0x0000000000000000000000000000000000000000' } },
  'base:native': { symbol: 'ETH', decimals: 18, decimalsSource: 'native constant', coingeckoId: 'ethereum', relay: { chainId: 8453, address: '0x0000000000000000000000000000000000000000' } },
  'eth:native': { symbol: 'ETH', decimals: 18, decimalsSource: 'native constant', coingeckoId: 'ethereum', relay: { chainId: 1, address: '0x0000000000000000000000000000000000000000' } },
  'near:eth.bridge.near': { symbol: 'ETH', decimals: 18, decimalsSource: 'ft_metadata', coingeckoId: null, oneclickCoingeckoId: 'ethereum', relay: null, unverified: 'no CoinGecko id for this contract' },
  'op:native': { symbol: 'ETH', decimals: 18, decimalsSource: 'native constant', coingeckoId: 'ethereum', relay: { chainId: 10, address: '0x0000000000000000000000000000000000000000' } },
  'eth:0x514910771af9ca656af840dff83e8264ecf986ca': { symbol: 'LINK', decimals: 18, decimalsSource: 'decimals()', coingeckoId: 'chainlink', relay: { chainId: 1, address: '0x514910771af9ca656af840dff83e8264ecf986ca' } },
  'ltc:native': { symbol: 'LTC', decimals: 8, decimalsSource: 'native constant', coingeckoId: 'litecoin', relay: null },
  'bsc:0x1fa4a73a3f0133f0025378af00236f3abdee5d63': { symbol: 'NEAR', decimals: 18, decimalsSource: 'decimals()', coingeckoId: 'binance-peg-near-protocol', oneclickCoingeckoId: 'near', relay: { chainId: 56, address: '0x1fa4a73a3f0133f0025378af00236f3abdee5d63' } },
  'op:0x4200000000000000000000000000000000000042': { symbol: 'OP', decimals: 18, decimalsSource: 'decimals()', coingeckoId: 'optimism', relay: { chainId: 10, address: '0x4200000000000000000000000000000000000042' } },
  'eth:0x6982508145454ce325ddbe47a25d4ec3d2311933': { symbol: 'PEPE', decimals: 18, decimalsSource: 'decimals()', coingeckoId: 'pepe', relay: { chainId: 1, address: '0x6982508145454ce325ddbe47a25d4ec3d2311933' } },
  'pol:native': { symbol: 'POL', decimals: 18, decimalsSource: 'native constant', coingeckoId: 'polygon-ecosystem-token', relay: { chainId: 137, address: '0x0000000000000000000000000000000000000000' } },
  'eth:0x95ad61b0a150d79219dcf64e1e6cc01f0b64c4ce': { symbol: 'SHIB', decimals: 18, decimalsSource: 'decimals()', coingeckoId: 'shiba-inu', relay: { chainId: 1, address: '0x95ad61b0a150d79219dcf64e1e6cc01f0b64c4ce' } },
  'sol:native': { symbol: 'SOL', decimals: 9, decimalsSource: 'native constant', coingeckoId: 'solana', relay: { chainId: 792703809, address: '11111111111111111111111111111111' } },
  'sui:native': { symbol: 'SUI', decimals: 9, decimalsSource: 'native constant', coingeckoId: 'sui', relay: null },
  'tron:native': { symbol: 'TRX', decimals: 6, decimalsSource: 'native constant', coingeckoId: 'tron', relay: null },
  'eth:0x1f9840a85d5af5bf1d1762f925bdaddc4201f984': { symbol: 'UNI', decimals: 18, decimalsSource: 'decimals()', coingeckoId: 'uniswap', relay: { chainId: 1, address: '0x1f9840a85d5af5bf1d1762f925bdaddc4201f984' } },
  'arb:0xaf88d065e77c8cc2239327c5edb3a432268e5831': { symbol: 'USDC', decimals: 6, decimalsSource: 'decimals()', coingeckoId: 'usd-coin', relay: { chainId: 42161, address: '0xaf88d065e77c8cc2239327c5edb3a432268e5831' } },
  'avax:0xb97ef9ef8734c71904d8002f8b6bc66dd9c48a6e': { symbol: 'USDC', decimals: 6, decimalsSource: 'decimals()', coingeckoId: 'usd-coin', relay: { chainId: 43114, address: '0xb97ef9ef8734c71904d8002f8b6bc66dd9c48a6e' } },
  'base:0x833589fcd6edb6e08f4c7c32d4f71b54bda02913': { symbol: 'USDC', decimals: 6, decimalsSource: 'decimals()', coingeckoId: 'usd-coin', relay: { chainId: 8453, address: '0x833589fcd6edb6e08f4c7c32d4f71b54bda02913' } },
  'bsc:0x8ac76a51cc950d9822d68b83fe1ad97b32cd580d': { symbol: 'USDC', decimals: 18, decimalsSource: 'decimals()', coingeckoId: 'binance-bridged-usdc-bnb-smart-chain', oneclickCoingeckoId: 'usd-coin', relay: { chainId: 56, address: '0x8ac76a51cc950d9822d68b83fe1ad97b32cd580d' } },
  'eth:0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48': { symbol: 'USDC', decimals: 6, decimalsSource: 'decimals()', coingeckoId: 'usd-coin', relay: { chainId: 1, address: '0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48' } },
  'gnosis:0x2a22f9c3b484c3629090feed35f17ff8f88f76f0': { symbol: 'USDC', decimals: 6, decimalsSource: 'decimals()', coingeckoId: 'bridged-usdc-gnosis', oneclickCoingeckoId: 'usd-coin', relay: { chainId: 100, address: '0x2a22f9c3b484c3629090feed35f17ff8f88f76f0' } },
  'near:17208628f84f5d6ad33f0da3bbbeb27ffcb398eac501a31bd6ad2011e36133a1': { symbol: 'USDC', decimals: 6, decimalsSource: 'ft_metadata', coingeckoId: 'usd-coin', relay: { chainId: 1, address: '0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48' } },
  'op:0x0b2c639c533813f4aa9d7837caf62653d097ff85': { symbol: 'USDC', decimals: 6, decimalsSource: 'decimals()', coingeckoId: 'usd-coin', relay: { chainId: 10, address: '0x0b2c639c533813f4aa9d7837caf62653d097ff85' } },
  'pol:0x3c499c542cef5e3811e1192ce70d8cc03d5c3359': { symbol: 'USDC', decimals: 6, decimalsSource: 'decimals()', coingeckoId: 'usd-coin', relay: { chainId: 137, address: '0x3c499c542cef5e3811e1192ce70d8cc03d5c3359' } },
  'sol:EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v': { symbol: 'USDC', decimals: 6, decimalsSource: 'Solana mint', coingeckoId: 'usd-coin', relay: { chainId: 792703809, address: 'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v' } },
  'sui:0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC': { symbol: 'USDC', decimals: 6, decimalsSource: 'Sui coinMetadata', coingeckoId: 'usd-coin', relay: { chainId: 1, address: '0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48' } },
  'avax:0x9702230a8ea53601f5cd2dc00fdbc13d4df4a8c7': { symbol: 'USDT', decimals: 6, decimalsSource: 'decimals()', coingeckoId: 'tether', relay: { chainId: 43114, address: '0x9702230a8ea53601f5cd2dc00fdbc13d4df4a8c7' } },
  'bsc:0x55d398326f99059ff775485246999027b3197955': { symbol: 'USDT', decimals: 18, decimalsSource: 'decimals()', coingeckoId: 'binance-bridged-usdt-bnb-smart-chain', oneclickCoingeckoId: 'tether', relay: { chainId: 56, address: '0x55d398326f99059ff775485246999027b3197955' } },
  'eth:0xdac17f958d2ee523a2206206994597c13d831ec7': { symbol: 'USDT', decimals: 6, decimalsSource: 'decimals()', coingeckoId: 'tether', relay: { chainId: 1, address: '0xdac17f958d2ee523a2206206994597c13d831ec7' } },
  'gnosis:0x4ecaba5870353805a9f068101a40e0f32ed605c6': { symbol: 'USDT', decimals: 6, decimalsSource: 'decimals()', coingeckoId: 'gnosis-xdai-bridged-usdt-gnosis', oneclickCoingeckoId: 'tether', relay: { chainId: 100, address: '0x4ecaba5870353805a9f068101a40e0f32ed605c6' } },
  'near:usdt.tether-token.near': { symbol: 'USDT', decimals: 6, decimalsSource: 'ft_metadata', coingeckoId: 'tether', relay: { chainId: 1, address: '0xdac17f958d2ee523a2206206994597c13d831ec7' } },
  'op:0x94b008aa00579c1307b0ef2c499ad98a8ce58e58': { symbol: 'USDT', decimals: 6, decimalsSource: 'decimals()', coingeckoId: 'bridged-usdt', oneclickCoingeckoId: 'tether', relay: { chainId: 10, address: '0x94b008aa00579c1307b0ef2c499ad98a8ce58e58' } },
  'pol:0xc2132d05d31c914a87c6611c10748aeb04b58e8f': { symbol: 'USDT', decimals: 6, decimalsSource: 'decimals()', coingeckoId: 'usdt0', oneclickCoingeckoId: 'tether', relay: { chainId: 137, address: '0xc2132d05d31c914a87c6611c10748aeb04b58e8f' } },
  'sol:Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB': { symbol: 'USDT', decimals: 6, decimalsSource: 'Solana mint', coingeckoId: 'tether', relay: { chainId: 792703809, address: 'Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB' } },
  'ton:EQCxE6mUtQJKFnGfaROTKOt1lZbDiiX1kCixRv7Nw2Id_sDs': { symbol: 'USDT', decimals: 6, decimalsSource: 'none', coingeckoId: 'tether', relay: { chainId: 1, address: '0xdac17f958d2ee523a2206206994597c13d831ec7' }, unverified: 'decimals not readable on chain' },
  'tron:TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t': { symbol: 'USDT', decimals: 6, decimalsSource: 'TRC-20 decimals()', coingeckoId: 'tether', relay: { chainId: 1, address: '0xdac17f958d2ee523a2206206994597c13d831ec7' } },
  'eth:0x2260fac5e5542a773aa44fbcfedf7c193bc2c599': { symbol: 'WBTC', decimals: 8, decimalsSource: 'decimals()', coingeckoId: 'wrapped-bitcoin', relay: { chainId: 1, address: '0x2260fac5e5542a773aa44fbcfedf7c193bc2c599' } },
  'near:2260fac5e5542a773aa44fbcfedf7c193bc2c599.factory.bridge.near': { symbol: 'WBTC', decimals: 8, decimalsSource: 'ft_metadata', coingeckoId: 'rainbow-bridged-wbtc-near-protocol', oneclickCoingeckoId: 'bitcoin', relay: null },
  'near:wrap.near': { symbol: 'WNEAR', decimals: 24, decimalsSource: 'ft_metadata', coingeckoId: 'wrapped-near', relay: null },
  'sol:3ZLekZYq2qkZiSpnSvabjit34tUkjSwD1JFuW9as9wBG': { symbol: 'WNEAR', decimals: 9, decimalsSource: 'Solana mint', coingeckoId: null, oneclickCoingeckoId: 'wrapped-near', relay: { chainId: 792703809, address: '3ZLekZYq2qkZiSpnSvabjit34tUkjSwD1JFuW9as9wBG' }, unverified: 'no CoinGecko id for this contract' },
  'xrp:native': { symbol: 'XRP', decimals: 6, decimalsSource: 'native constant', coingeckoId: 'ripple', relay: null },
};

const key = (t: Pick<TokenRow, 'blockchain' | 'contractAddress'>) => {
  const c = t.contractAddress;
  if (!c) return `${t.blockchain}:native`;
  return `${t.blockchain}:${/^0x[0-9a-fA-F]{40}$/.test(c) ? c.toLowerCase() : c}`;
};

/** The pin for a 1Click row, checked against it: refused on any disagreement, not verified when unpinned or unverified. */
export function checkPin(t: TokenRow): { ok: true; pin: VerifiedPin } | { ok: false; refused: string | null; reason: string } {
  const pin = PINS[key(t)];
  const name = `${t.symbol} on ${t.blockchain}`;
  if (!pin) return { ok: false, refused: null, reason: `${name} is not on Pip's pinned list` };
  const bad = (what: string, row: unknown, ours: unknown) => ({ ok: false as const, refused: `1Click's ${name} ${what} (${row}) differs from Pip's pin (${ours})`, reason: '' });
  if (t.symbol.toUpperCase() !== pin.symbol) return bad('symbol', t.symbol, pin.symbol);
  if (t.decimals !== pin.decimals) return bad('decimals', t.decimals, pin.decimals);
  if (t.coingeckoId !== undefined && t.coingeckoId !== pin.coingeckoId && t.coingeckoId !== pin.oneclickCoingeckoId) return bad('CoinGecko id', t.coingeckoId, pin.coingeckoId);
  if (pin.unverified || !pin.coingeckoId) return { ok: false, refused: null, reason: `${name} is not verified: ${pin.unverified ?? 'no CoinGecko id'}` };
  return { ok: true, pin: pin as VerifiedPin };
}
