import { payConfig, type Token } from './config.ts';

export type Payment = { amount: string; token: Token; recipient: string };
export type ParseResult = ({ valid: true } & Payment) | { valid: false; reason: string };

const VERB = String.raw`(?:send|pay|transfer|give)`;
const AMOUNT = String.raw`(\S+?)`;
const TOKEN = String.raw`(near|usdc)`;
// Anything that looks like a target; the account id rules are checked after the match, so a bad id gets a clear reason.
const TARGET = String.raw`(@?[^\s,;!?]+?)`;
const END = String.raw`(?=[\s,;!?]|\.(?:\s|$)|$)`;
// "send 5 USDC to ana.testnet" or "pay ana.testnet 5 USDC". Only these two shapes; nothing is guessed.
const SHAPES: { re: RegExp; amount: number; token: number; to: number }[] = [
  { re: new RegExp(String.raw`\b${VERB}\s+${AMOUNT}\s*${TOKEN}\s+to\s+${TARGET}${END}`, 'gi'), amount: 1, token: 2, to: 3 },
  { re: new RegExp(String.raw`\b${VERB}\s+${TARGET}\s+${AMOUNT}\s*${TOKEN}${END}`, 'gi'), amount: 2, token: 3, to: 1 },
];

const ACCOUNT_ID = /^(?=.{2,64}$)(([a-z\d]+[-_])*[a-z\d]+\.)*([a-z\d]+[-_])*[a-z\d]+$/;
const IMPLICIT = /^[0-9a-f]{64}$/;

/** A testnet account id, or the reason it is not one. A bare name like "ana" is refused, never guessed. */
export function checkRecipient(raw: string): { ok: true; id: string } | { ok: false; reason: string } {
  const id = raw.replace(/^@/, '').replace(/\.$/, '');
  if (id !== id.toLowerCase()) return { ok: false, reason: 'account ids are lower case' };
  if (!ACCOUNT_ID.test(id)) return { ok: false, reason: 'not a NEAR account id' };
  if (IMPLICIT.test(id) || id.endsWith('.testnet')) return { ok: true, id };
  if (id.endsWith('.near')) return { ok: false, reason: 'mainnet accounts are not allowed; use a .testnet account' };
  if (!id.includes('.')) return { ok: false, reason: `write the full account id, like ${id}.testnet` };
  return { ok: false, reason: 'only .testnet accounts are allowed' };
}

/** A plain decimal amount ("5", "0.01", "5.50"), above zero, with no more decimals than the token has. */
export function checkAmount(raw: string, token: Token): { ok: true; amount: string } | { ok: false; reason: string } {
  if (!/^\d{1,12}(\.\d+)?$/.test(raw)) return { ok: false, reason: 'write the amount as a plain number, like 5 or 0.5' };
  const [whole, frac = ''] = raw.split('.');
  if (frac.length > payConfig.decimals[token]) return { ok: false, reason: `${token} has at most ${payConfig.decimals[token]} decimals` };
  const amount = `${BigInt(whole)}${frac.replace(/0+$/, '') ? `.${frac.replace(/0+$/, '')}` : ''}`;
  if (toUnits(amount, token) === 0n) return { ok: false, reason: 'the amount must be more than zero' };
  return { ok: true, amount };
}

/** "1.5" NEAR -> 1500000000000000000000000n. Only for amounts checkAmount accepted. */
export function toUnits(amount: string, token: Token): bigint {
  const d = payConfig.decimals[token];
  const [whole, frac = ''] = amount.split('.');
  return BigInt(whole) * 10n ** BigInt(d) + BigInt((frac + '0'.repeat(d)).slice(0, d) || '0');
}

export function fromUnits(units: bigint, token: Token): string {
  const d = payConfig.decimals[token];
  const s = units.toString().padStart(d + 1, '0');
  const frac = s.slice(-d).replace(/0+$/, '');
  return frac ? `${s.slice(0, -d)}.${frac}` : s.slice(0, -d);
}

/** Checks the three fields a client sends back (an intent body). Same rules as parsing. */
export function checkPayment(p: { amount: string; token: string; recipient: string }): ParseResult {
  const token = p.token.toUpperCase();
  if (token !== 'NEAR' && token !== 'USDC') return { valid: false, reason: 'token must be NEAR or USDC' };
  const a = checkAmount(p.amount, token);
  if (!a.ok) return { valid: false, reason: a.reason };
  const r = checkRecipient(p.recipient);
  if (!r.ok) return { valid: false, reason: r.reason };
  return { valid: true, amount: a.amount, token, recipient: r.id };
}

/** Reads one payment from a line of text with fixed patterns. No model, no network. */
export function parsePayment(text: string): ParseResult {
  const found = SHAPES.flatMap((s) => [...text.matchAll(s.re)].map((m) => ({ at: m.index, amount: m[s.amount], token: m[s.token], to: m[s.to] })));
  const unique = [...new Map(found.map((f) => [f.at, f])).values()];
  if (unique.length === 0) return { valid: false, reason: 'no payment found; try "send 5 USDC to ana.testnet"' };
  if (unique.length > 1) return { valid: false, reason: 'more than one payment in the text; send one at a time' };
  const f = unique[0];
  return checkPayment({ amount: f.amount, token: f.token, recipient: f.to });
}
