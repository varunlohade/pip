import type { TokenRow } from './assets.ts';
import type { Pin } from './pins.ts';

/** The parts of a 1Click quote response Pip reads. Every amount is a base-unit integer string. */
export type OneClickQuote = {
  quote: {
    depositAddress?: string; depositMemo?: string; amountIn: string; amountInFormatted: string; amountInUsd?: string; minAmountIn: string;
    amountOut: string; amountOutFormatted: string; amountOutUsd?: string; minAmountOut: string; deadline?: string; timeEstimate: number;
    refundFee?: string; withdrawFee?: string;
  };
  quoteRequest: Record<string, unknown>;
  signature: string; timestamp: string; correlationId: string;
};
export type OneClickStatus = {
  status: 'KNOWN_DEPOSIT_TX' | 'PENDING_DEPOSIT' | 'INCOMPLETE_DEPOSIT' | 'PROCESSING' | 'SUCCESS' | 'REFUNDED' | 'FAILED';
  updatedAt?: string;
  swapDetails?: { amountOut?: string; refundedAmount?: string; refundReason?: string; destinationChainTxHashes?: { hash: string; explorerUrl: string }[]; nearTxHashes?: string[] };
};

/** NEAR Intents 1Click. Tests pass a fake. */
export type OneClick = {
  tokens(): Promise<TokenRow[]>;
  quote(req: Record<string, unknown>): Promise<OneClickQuote>;
  status(depositAddress: string): Promise<OneClickStatus>;
  submitDeposit(body: { txHash: string; depositAddress: string; nearSenderAccount: string }): Promise<void>;
};

/** A USD price per whole token, as the source sent it (string or number). Null when the source has none. Lookups use Pip's pin. */
export type PriceSource = { name: string; price(t: TokenRow, pin: Pin): Promise<string | number | null> };

const env = process.env;
const TIMEOUT = 8_000;

async function getJson(url: string, init: RequestInit = {}): Promise<unknown> {
  const r = await fetch(url, { ...init, signal: AbortSignal.timeout(TIMEOUT) });
  const body = await r.json().catch(() => null);
  if (!r.ok) throw new Error(`${new URL(url).host} ${r.status}: ${(body as { message?: string } | null)?.message ?? ''}`.trim());
  return body;
}

/**
 * The live 1Click API. No key is needed; ONECLICK_API_KEY (X-API-Key) is optional and removes 1Click's own small fee.
 * The token list is cached for 10 minutes.
 */
export function createOneClick(base = env.ONECLICK_BASE_URL ?? 'https://1click.chaindefuser.com', apiKey = env.ONECLICK_API_KEY ?? ''): OneClick {
  const headers: Record<string, string> = { 'content-type': 'application/json', ...(apiKey ? { 'x-api-key': apiKey } : {}) };
  let cache: { at: number; rows: TokenRow[] } | undefined;
  return {
    async tokens() {
      if (cache && Date.now() - cache.at < 10 * 60_000) return cache.rows;
      const rows = (await getJson(`${base}/v0/tokens`, { headers })) as TokenRow[];
      if (!Array.isArray(rows)) throw new Error('1Click tokens: not a list');
      cache = { at: Date.now(), rows };
      return rows;
    },
    async quote(req) {
      return (await getJson(`${base}/v0/quote`, { method: 'POST', headers, body: JSON.stringify(req) })) as OneClickQuote;
    },
    async status(depositAddress) {
      return (await getJson(`${base}/v0/status?depositAddress=${encodeURIComponent(depositAddress)}`, { headers })) as OneClickStatus;
    },
    async submitDeposit(body) {
      await getJson(`${base}/v0/deposit/submit`, { method: 'POST', headers, body: JSON.stringify(body) });
    },
  };
}

/** CoinGecko's free simple-price API, by the pinned CoinGecko id. */
export function coingeckoSource(base = 'https://api.coingecko.com/api/v3'): PriceSource {
  return {
    name: 'coingecko',
    async price(_t, pin) {
      const r = (await getJson(`${base}/simple/price?ids=${encodeURIComponent(pin.coingeckoId)}&vs_currencies=usd`)) as Record<string, { usd?: number }>;
      return r?.[pin.coingeckoId]?.usd ?? null;
    },
  };
}

/** Relay's keyless token price API (v2). Relay has no NEAR chain; NEAR-side coins are priced through their Ethereum twin. */
export function relaySource(base = 'https://api.relay.link'): PriceSource {
  return {
    name: 'relay',
    async price(_t, pin) {
      const a = pin.relay;
      if (!a) return null;
      const r = (await getJson(`${base}/currencies/token/price/v2?address=${encodeURIComponent(a.address)}&chainId=${a.chainId}`)) as { price?: string | number };
      return r?.price ?? null;
    },
  };
}
