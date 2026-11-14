import { baseDecode } from 'near-api-js';
import { CHAINS, type TokenRow } from './assets.ts';

/** Reads a token's decimals from its own chain. Null when it cannot. Tests pass a fake. */
export type ChainDecimals = (t: TokenRow) => Promise<number | null>;

const env = process.env;
const RPC: Record<string, string> = {
  near: env.NEAR_MAINNET_RPC_URL ?? 'https://free.rpc.fastnear.com',
  eth: 'https://ethereum-rpc.publicnode.com',
  base: 'https://base-rpc.publicnode.com',
  arb: 'https://arbitrum-one-rpc.publicnode.com',
  op: 'https://optimism-rpc.publicnode.com',
  pol: 'https://polygon-bor-rpc.publicnode.com',
  avax: 'https://avalanche-c-chain-rpc.publicnode.com',
  bsc: 'https://bsc-rpc.publicnode.com',
  gnosis: 'https://gnosis-rpc.publicnode.com',
  sol: 'https://api.mainnet-beta.solana.com',
  tron: 'https://api.trongrid.io/jsonrpc',
};
/** Native coins have no contract to ask; their decimals are fixed by the chain itself. */
const NATIVE: Record<string, { symbol: string; decimals: number }> = {
  eth: { symbol: 'ETH', decimals: 18 }, base: { symbol: 'ETH', decimals: 18 }, arb: { symbol: 'ETH', decimals: 18 }, op: { symbol: 'ETH', decimals: 18 },
  pol: { symbol: 'POL', decimals: 18 }, avax: { symbol: 'AVAX', decimals: 18 }, bsc: { symbol: 'BNB', decimals: 18 }, gnosis: { symbol: 'XDAI', decimals: 18 },
  sol: { symbol: 'SOL', decimals: 9 }, tron: { symbol: 'TRX', decimals: 6 },
};

async function rpc(url: string, method: string, params: unknown): Promise<unknown> {
  const r = await fetch(url, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }), signal: AbortSignal.timeout(8_000) });
  const body = (await r.json()) as { result?: unknown; error?: unknown };
  if (!r.ok || body.error) throw new Error(`${method} failed`);
  return body.result;
}

/** decimals() (0x313ce567) as an eth_call. Tron's JSON-RPC takes the same call with the 20-byte hex address. */
async function evmDecimals(url: string, address: string): Promise<number | null> {
  const r = await rpc(url, 'eth_call', [{ to: address, data: '0x313ce567' }, 'latest']);
  return typeof r === 'string' && /^0x[0-9a-f]{64}$/i.test(r) ? Number(BigInt(r)) : null;
}

/**
 * Live decimals: ft_metadata on NEAR, decimals() on EVM and Tron, the mint account on Solana, the chain's own native decimals.
 * Answers are cached per asset id: a token's decimals do not change.
 */
export function createChainDecimals(): ChainDecimals {
  const cache = new Map<string, number>();
  return async (t) => {
    const hit = cache.get(t.assetId);
    if (hit !== undefined) return hit;
    const url = RPC[t.blockchain];
    if (!url || !CHAINS[t.blockchain]) return null;
    const c = t.contractAddress;
    let d: number | null = null;
    if (!c) d = NATIVE[t.blockchain]?.symbol === t.symbol.toUpperCase() ? NATIVE[t.blockchain].decimals : null;
    else if (t.blockchain === 'near') {
      const r = (await rpc(url, 'query', { request_type: 'call_function', finality: 'final', account_id: c, method_name: 'ft_metadata', args_base64: 'e30=' })) as { result?: number[] };
      const meta = r?.result ? JSON.parse(Buffer.from(r.result).toString()) as { decimals?: unknown } : null;
      d = typeof meta?.decimals === 'number' ? meta.decimals : null;
    } else if (CHAINS[t.blockchain].kind === 'evm') d = await evmDecimals(url, c);
    else if (t.blockchain === 'tron') d = await evmDecimals(url, `0x${Buffer.from(baseDecode(c).subarray(1, 21)).toString('hex')}`);
    else if (t.blockchain === 'sol') {
      const r = (await rpc(url, 'getAccountInfo', [c, { encoding: 'jsonParsed' }])) as { value?: { data?: { parsed?: { type?: string; info?: { decimals?: unknown } } } } };
      const p = r?.value?.data?.parsed;
      d = p?.type === 'mint' && typeof p.info?.decimals === 'number' ? p.info.decimals : null;
    }
    if (d !== null && Number.isInteger(d)) cache.set(t.assetId, d);
    return d;
  };
}
