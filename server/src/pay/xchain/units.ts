/** Exact amount math for cross-chain payments. Every amount is a bigint in base units; no float touches an amount. */

/** "1.5" with 6 decimals -> 1500000n. Null when the text is not a plain decimal or has more decimals than the token. */
export function toBase(text: string, decimals: number): bigint | null {
  const m = /^(\d{1,30})(?:\.(\d+))?$/.exec(text);
  if (!m) return null;
  const frac = (m[2] ?? '').replace(/0+$/, '');
  if (frac.length > decimals) return null;
  return BigInt(m[1]) * 10n ** BigInt(decimals) + BigInt((frac + '0'.repeat(decimals)).slice(0, decimals) || '0');
}

/** 1500000n with 6 decimals -> "1.5". */
export function fromBase(units: bigint, decimals: number): string {
  const neg = units < 0n;
  const s = (neg ? -units : units).toString().padStart(decimals + 1, '0');
  const whole = decimals ? s.slice(0, -decimals) : s;
  const frac = decimals ? s.slice(-decimals).replace(/0+$/, '') : '';
  return `${neg ? '-' : ''}${whole}${frac ? `.${frac}` : ''}`;
}

/** USD prices and values use fixed scales: a price in 1e-12 USD, a value in 1e-6 USD (micro-dollars). */
export const PRICE_SCALE = 10n ** 12n;
export const USD_SCALE = 10n ** 6n;

/**
 * A price from JSON ("2.79", 2.79, "1.2e-7") as a bigint in 1e-12 USD. Null when it is not a positive decimal.
 * The JSON number is read through its shortest decimal string, so no float arithmetic is done.
 */
export function parsePrice(raw: unknown): bigint | null {
  if (typeof raw !== 'string' && typeof raw !== 'number') return null;
  const m = /^(\d+)(?:\.(\d+))?(?:e([+-]?\d+))?$/i.exec(String(raw).trim());
  if (!m) return null;
  const digits = m[1] + (m[2] ?? '');
  const shift = 12 + Number(m[3] ?? 0) - (m[2]?.length ?? 0);
  if (shift < -40 || shift > 40) return null;
  const v = shift >= 0 ? BigInt(digits) * 10n ** BigInt(shift) : BigInt(digits) / 10n ** BigInt(-shift);
  return v > 0n ? v : null;
}

/** Value of `units` at `price` (1e-12 USD per whole token), in micro-dollars, rounded down. */
export const usdValue = (units: bigint, decimals: number, price: bigint): bigint =>
  (units * price) / (10n ** BigInt(decimals) * (PRICE_SCALE / USD_SCALE));

/** |a - b| / b in basis points, rounded up so a limit is never passed by rounding. */
export function diffBps(a: bigint, b: bigint): bigint {
  if (b <= 0n) return 10_000n;
  const d = a > b ? a - b : b - a;
  return (d * 10_000n + b - 1n) / b;
}

/** Micro-dollars -> "1.234567". */
export const usdText = (micro: bigint) => fromBase(micro, 6);
