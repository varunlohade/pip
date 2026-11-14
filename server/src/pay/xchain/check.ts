import type { TokenRow } from './assets.ts';
import type { OneClickQuote } from './sources.ts';
import { diffBps, fromBase, parsePrice, toBase, usdText, usdValue } from './units.ts';

export type Mode = 'exact_out' | 'exact_in';
export type Limits = { maxFeeBps: bigint; maxFeeUsdMicro: bigint; maxRateDiffBps: bigint; maxPriceSpreadBps: bigint; slippageBps: number };
export type Prices = { source: string; price: unknown }[];

export const defaultLimits = (env = process.env): Limits => ({
  maxFeeBps: BigInt(env.XCHAIN_MAX_FEE_BPS ?? '300'),
  maxFeeUsdMicro: BigInt(env.XCHAIN_MAX_FEE_USD_MICRO ?? '1000000'),
  maxRateDiffBps: BigInt(env.XCHAIN_MAX_RATE_DIFF_BPS ?? '200'),
  maxPriceSpreadBps: BigInt(env.XCHAIN_MAX_PRICE_SPREAD_BPS ?? '200'),
  slippageBps: Number(env.XCHAIN_SLIPPAGE_BPS ?? '100'),
});

/** The typed amount in base units of the side it names: the destination for exact_out, the origin for exact_in. Never rounded. */
export function typedUnits(amount: string, mode: Mode, origin: TokenRow, dest: TokenRow): { ok: true; units: bigint } | { ok: false; reason: string } {
  const t = mode === 'exact_out' ? dest : origin;
  const units = toBase(amount, t.decimals);
  if (units === null) return { ok: false, reason: /^\d+(\.\d+)?$/.test(amount) ? `${t.symbol} on ${t.blockchain} has at most ${t.decimals} decimals` : 'write the amount as a plain number' };
  if (units === 0n) return { ok: false, reason: 'the amount must be more than zero' };
  return { ok: true, units };
}

/** The 1Click quote request. `dry` true never makes a deposit address. */
export function quoteRequest(p: { mode: Mode; units: bigint; origin: TokenRow; dest: TokenRow; recipient: string; refundTo: string; deadline: Date; slippageBps: number; dry: boolean }) {
  return {
    dry: p.dry, swapType: p.mode === 'exact_out' ? 'EXACT_OUTPUT' : 'EXACT_INPUT', slippageTolerance: p.slippageBps,
    originAsset: p.origin.assetId, depositType: 'ORIGIN_CHAIN', destinationAsset: p.dest.assetId, amount: p.units.toString(),
    refundTo: p.refundTo, refundType: 'ORIGIN_CHAIN', recipient: p.recipient, recipientType: 'DESTINATION_CHAIN',
    deadline: p.deadline.toISOString(), depositMode: 'SIMPLE',
  };
}

/** One price per asset from at least two sources that agree. The first source in the list is the reference. */
export function agreedPrice(prices: Prices, maxSpreadBps: bigint): { ok: true; price: bigint; sources: string[] } | { ok: false; reason: string } {
  const ok = prices.map((p) => ({ source: p.source, v: parsePrice(p.price) })).filter((p): p is { source: string; v: bigint } => p.v !== null);
  if (ok.length < 2) return { ok: false, reason: `only ${ok.length} price source answered` };
  const ref = ok[0].v;
  const off = ok.find((p) => diffBps(p.v, ref) > maxSpreadBps);
  if (off) return { ok: false, reason: `${off.source} and ${ok[0].source} prices differ by more than ${maxSpreadBps} bps` };
  return { ok: true, price: ref, sources: ok.map((p) => p.source) };
}

const INT = /^[1-9]\d*$/;
export type Amount = { units: string; text: string; symbol: string; chain: string; decimals: number };
const amt = (units: bigint, t: TokenRow): Amount => ({ units: units.toString(), text: fromBase(units, t.decimals), symbol: t.symbol, chain: t.blockchain, decimals: t.decimals });

export type Numbers = {
  mode: Mode; amount_in: Amount; max_amount_in: Amount; min_amount_in: Amount; amount_out: Amount; min_amount_out: Amount;
  fee: { in_origin: Amount; usd: string | null; bps: string | null };
  rate: { text: string; one: string } ; eta_seconds: number;
  usd: { in: string | null; out: string | null; price_sources: Record<string, string[]> };
};
export type Verdict =
  | { ok: true; verified: true; numbers: Numbers }
  | { ok: false; verified: false; refused: string | null; not_verified: string[]; numbers: Numbers | null };

/**
 * Every check on one quote, with bigint math only. A hard mismatch refuses; a missing second source leaves it not verified.
 * Either way the server makes no signable payment from it.
 */
export function checkQuote(p: {
  mode: Mode; typed: bigint; origin: TokenRow; dest: TokenRow; chainDecimals: { origin: number | null; dest: number | null };
  sent: Record<string, unknown>; q: OneClickQuote; prices: { origin: Prices; dest: Prices }; limits: Limits; now: number; minDeadlineMs: number;
}): Verdict {
  const { origin: o, dest: d, q, limits } = p;
  const refuse = (refused: string, numbers: Numbers | null = null): Verdict => ({ ok: false, verified: false, refused, not_verified: [], numbers });

  // 1. Decimals: the token list and the token's own chain must agree, per asset.
  for (const [side, t, live] of [['origin', o, p.chainDecimals.origin], ['destination', d, p.chainDecimals.dest]] as const) {
    if (live === null) return refuse(`could not read ${t.symbol} decimals on ${t.blockchain}`);
    if (live !== t.decimals) return refuse(`${side} ${t.symbol} decimals differ: token list ${t.decimals}, chain ${live}`);
  }
  // 2. The quote answers the request we sent, field by field.
  for (const k of ['dry', 'swapType', 'originAsset', 'destinationAsset', 'amount', 'recipient', 'refundTo', 'depositType', 'recipientType', 'refundType']) {
    if (q.quoteRequest?.[k] !== p.sent[k]) return refuse(`the quote does not match the request (${k})`);
  }
  // 3. Integers, and each formatted amount is its base units at that asset's decimals.
  const x = q.quote;
  for (const k of ['amountIn', 'minAmountIn', 'amountOut', 'minAmountOut'] as const) if (!INT.test(String(x?.[k]))) return refuse(`the quote has a bad ${k}`);
  const aIn = BigInt(x.amountIn), minIn = BigInt(x.minAmountIn), aOut = BigInt(x.amountOut), minOut = BigInt(x.minAmountOut);
  if (toBase(String(x.amountInFormatted), o.decimals) !== aIn) return refuse(`the quote's ${o.symbol} amount does not fit ${o.decimals} decimals`);
  if (toBase(String(x.amountOutFormatted), d.decimals) !== aOut) return refuse(`the quote's ${d.symbol} amount does not fit ${d.decimals} decimals`);
  if (minIn > aIn || minOut > aOut) return refuse('the quote minimums are above its amounts');
  // 4. The side the user typed is exact.
  if (p.mode === 'exact_out' && (aOut !== p.typed || minOut !== p.typed)) return refuse('the quote does not deliver the exact amount typed');
  if (p.mode === 'exact_in' && aIn !== p.typed) return refuse('the quote does not spend the exact amount typed');
  // 5. A real quote: a NEAR deposit account, no memo, and enough time before the deposit address goes cold.
  if (p.sent.dry === false) {
    const dep = String(x.depositAddress ?? '');
    if (!/^[0-9a-f]{64}$/.test(dep) && !/^(([a-z\d]+[-_])*[a-z\d]+\.)+near$/.test(dep)) return refuse('the quote has no NEAR deposit account');
    if (x.depositMemo) return refuse('the quote needs a memo; Pip does not send memos');
    const dl = Date.parse(String(x.deadline ?? ''));
    if (!(dl >= p.now + p.minDeadlineMs)) return refuse('the quote deadline is too close');
  }

  // 6. Prices: two sources per asset, within the spread.
  const numbersBase = (feeIn: bigint, usd: Numbers['usd'], fee: Pick<Numbers['fee'], 'usd' | 'bps'>): Numbers => ({
    mode: p.mode, amount_in: amt(aIn, o), max_amount_in: amt(aIn, o), min_amount_in: amt(minIn, o), amount_out: amt(aOut, d), min_amount_out: amt(minOut, d),
    fee: { in_origin: amt(feeIn, o), ...fee },
    rate: { text: `1 ${o.symbol} = ${fromBase((aOut * 10n ** BigInt(o.decimals)) / aIn, d.decimals)} ${d.symbol}`, one: fromBase((aOut * 10n ** BigInt(o.decimals)) / aIn, d.decimals) },
    eta_seconds: Number(x.timeEstimate) || 0, usd,
  });
  const pin = agreedPrice(p.prices.origin, limits.maxPriceSpreadBps);
  const pout = agreedPrice(p.prices.dest, limits.maxPriceSpreadBps);
  const notVerified = [...(pin.ok ? [] : [`${o.symbol} price: ${pin.reason}`]), ...(pout.ok ? [] : [`${d.symbol} price: ${pout.reason}`])];
  if (!pin.ok || !pout.ok) {
    return { ok: false, verified: false, refused: null, not_verified: notVerified, numbers: numbersBase(0n, { in: null, out: null, price_sources: {} }, { usd: null, bps: null }) };
  }
  // 7. Value, fee and rate in micro-dollars. The fee is what the max input is worth above the output.
  const vin = usdValue(aIn, o.decimals, pin.price), vout = usdValue(aOut, d.decimals, pout.price);
  const feeUsd = vin > vout ? vin - vout : 0n;
  const feeBps = vin > 0n ? (feeUsd * 10_000n + vin - 1n) / vin : 10_000n;
  const outAsIn = (aOut * pout.price * 10n ** BigInt(o.decimals)) / (pin.price * 10n ** BigInt(d.decimals));
  const feeIn = aIn > outAsIn ? aIn - outAsIn : 0n;
  const numbers = numbersBase(feeIn, { in: usdText(vin), out: usdText(vout), price_sources: { origin: pin.sources, destination: pout.sources } }, { usd: usdText(feeUsd), bps: feeBps.toString() });
  // 1Click's own USD figures must match ours: catches a wrong price or decimals on its side.
  for (const [k, ours] of [['amountInUsd', vin], ['amountOutUsd', vout]] as const) {
    const theirs = toBase(String(x[k] ?? '').replace(/^(\d+\.\d{6})\d*$/, '$1'), 6);
    if (theirs === null) return { ok: false, verified: false, refused: null, not_verified: [`1Click gave no ${k}`], numbers };
    if (diffBps(theirs, ours) > limits.maxRateDiffBps) return refuse(`the quote's rate is more than ${limits.maxRateDiffBps} bps from market prices`, numbers);
  }
  if (feeBps > limits.maxFeeBps) return refuse(`the fee is ${feeBps} bps, above ${limits.maxFeeBps}`, numbers);
  if (feeUsd > limits.maxFeeUsdMicro) return refuse(`the fee is $${usdText(feeUsd)}, above $${usdText(limits.maxFeeUsdMicro)}`, numbers);
  return { ok: true, verified: true, numbers };
}
