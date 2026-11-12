import { z } from 'zod';
import { log } from './log.ts';

/** Keyless daily reference rates (European Central Bank), one call per hour at most. */
export const RATES_URL = 'https://api.frankfurter.dev/v1/latest?base=USD';
export const RATES_TTL_MS = 3_600_000;

const Source = z.object({
  base: z.literal('USD'),
  date: z.string().regex(/^\d{4}-\d{2}-\d{2}$/),
  rates: z.record(z.string().regex(/^[A-Z]{3}$/), z.number().positive().finite()),
});

/** GET /v1/rates: units of each currency for one US dollar. `date` is the source's day; `fetched_at` is when the server read it. */
export type RatesOut = { base: 'USD'; date: string; fetched_at: string; rates: Record<string, number> };

export type Rates = { get(): Promise<RatesOut> };

/** The rates, cached for an hour. A failed refresh keeps serving the last good rates; with none, it throws. */
export function createRates(deps: { fetch?: typeof fetch; now?: () => number; url?: string } = {}): Rates {
  const now = deps.now ?? Date.now;
  let cached: { out: RatesOut; at: number } | undefined;
  let inflight: Promise<RatesOut> | undefined;

  const load = async (): Promise<RatesOut> => {
    const f = deps.fetch ?? fetch;
    const res = await f(deps.url ?? RATES_URL, { signal: AbortSignal.timeout(8000) });
    if (!res.ok) throw new Error(`rates source ${res.status}`);
    const src = Source.parse(await res.json());
    const at = now();
    const out: RatesOut = { base: 'USD', date: src.date, fetched_at: new Date(at).toISOString(), rates: { ...src.rates, USD: 1 } };
    cached = { out, at };
    return out;
  };

  return {
    async get() {
      if (cached && now() - cached.at < RATES_TTL_MS) return cached.out;
      inflight ??= load().finally(() => { inflight = undefined; });
      try {
        return await inflight;
      } catch (e) {
        log('rates', { ok: false, err: (e as Error).message.slice(0, 80), stale: !!cached });
        if (!cached) throw e;
        // Try the source again in five minutes, not on every call.
        cached.at = now() - RATES_TTL_MS + 300_000;
        return cached.out;
      }
    },
  };
}
