import { BARE } from '../parse.ts';
import { CHAINS, ORIGINS, addressChain, chainByName, checkAddress, type Origin } from './assets.ts';

export type XchainPayment = { amount: string; token: string; chain: string; recipient: string; from: Origin | null; tag: string | null };
export type XchainParse =
  | ({ valid: true; kind: 'near' | 'xchain' } & XchainPayment)
  | { valid: false; reason: string; needs?: 'chain' };

const VERB = String.raw`(?:send|pay|transfer|give)`;
const ON = String.raw`(?:\s+(?:on|via)\s+(?:the\s+)?([a-z]+)(?:\s+(?:chain|network))?)?`;
const TAG = String.raw`(?:\s+(?:destination\s+)?(?:tag|memo)\s+(\d{1,10}))?`;
const FROM = String.raw`(?:\s+from\s+(?:my\s+)?([a-z]+)(?:\s+(?:wallet|balance|account))?)?`;
const END = String.raw`(?=[\s,;!?]|\.(?:\s|$)|$)`;
// "send 20 USDT on solana to <addr> from my NEAR", "pay 0.01 ETH to 0x… on base". One shape; nothing is guessed.
// The verb may be left out ("5 usdc to 0x… on base"); then the target must be an address Pip knows (see parseXchain).
const SHAPE = new RegExp(String.raw`(?:\b(${VERB})\s+|${BARE}(?=\d))(\S+?)\s*([a-z][a-z0-9]{1,9})${ON}\s+to\s+(@?[^\s,;!?]+?)${TAG}${ON}${FROM}${END}`, 'gi');

// "$" with a dollar stablecoin is only the unit: "$0.02 USDT" is "0.02 USDT", "5 bucks of usdc" is "5 USDC", and a bare "$5" is "5 USDC".
// The number itself is never touched (docs/XCHAIN-NUMBERS.md). "$5 ETH" stays as typed, so it fails as before: dollars or ETH is unclear.
const DOLLAR_TOKENS = 'usdc|usdt|dai|usd1|pyusd|fdusd|usde|usds';
export function dollarsAsUnit(text: string): string {
  return text
    .replace(new RegExp(String.raw`\$\s?(\d[\d.]*)\s*(${DOLLAR_TOKENS})\b`, 'gi'), '$1 $2')
    .replace(new RegExp(String.raw`\b(\d[\d.]*)\s+(?:bucks|dollars|usd)\s+(?:of|in|worth\s+of)\s+(${DOLLAR_TOKENS})\b`, 'gi'), '$1 $2')
    .replace(new RegExp(String.raw`\b(${VERB})\s+\$\s?(\d[\d.]*)(?=\s+to\s)`, 'gi'), '$1 $2 USDC')
    .replace(new RegExp(String.raw`${BARE}\$\s?(\d[\d.]*)(?=\s+to\s)`, 'gi'), '$1 USDC');
}

const BAD_AMOUNT = 'write the amount as a plain number above zero, like 5 or 0.5';
/** "05.50" -> "5.5". Null for anything that is not a plain number above zero. The digits are never rounded. */
function cleanAmount(raw: string): string | null {
  if (!/^\d{1,12}(\.\d{1,30})?$/.test(raw) || !/[1-9]/.test(raw)) return null;
  return raw.includes('.') ? raw.replace(/\.?0+$/, '').replace(/^0+(?=\d)/, '') : raw.replace(/^0+(?=\d)/, '');
}

/** Reads one any-token, any-chain payment from a line of text. Pure: no network. Decimals are checked later against the token list. */
export function parseXchain(text: string): XchainParse {
  // A match with no verb counts only when its target is an address: "1 near to usdc" stays a swap, "5 usdc to my mom" stays words.
  const isAddress = (raw: string) => { const t = raw.replace(/^@/, '').replace(/\.$/, ''); return !!(addressChain(t) || addressChain(t.toLowerCase())); };
  const found = [...dollarsAsUnit(text).matchAll(SHAPE)].filter((m) => m[1] || isAddress(m[5]));
  if (found.length === 0) return { valid: false, reason: 'no payment found; try "send 5 USDC to 0x… on base"' };
  if (found.length > 1) return { valid: false, reason: 'more than one payment in the text; send one at a time' };
  const [, , amountRaw, tokenRaw, on1, targetRaw, tagRaw, on2, fromRaw] = found[0];
  const amount = cleanAmount(amountRaw);
  if (!amount) return { valid: false, reason: BAD_AMOUNT };
  const token = tokenRaw.toUpperCase();
  const recipient = targetRaw.replace(/^@/, '').replace(/\.$/, '');

  const named = [on1, on2].filter(Boolean).map((n) => ({ raw: n!, id: chainByName(n!) }));
  const bad = named.find((n) => !n.id);
  if (bad) return { valid: false, reason: `Pip does not pay to ${bad.raw} yet` };
  if (named.length === 2 && named[0].id !== named[1].id) return { valid: false, reason: 'two different chains named; name one' };
  let chain = named[0]?.id ?? null;
  if ((chain === null || chain === 'near') && recipient !== recipient.toLowerCase() && addressChain(recipient.toLowerCase()) === 'near') return { valid: false, reason: 'NEAR account ids are lower case' };
  if (!chain) {
    const found = addressChain(recipient);
    if (found === 'evm' || found === 'ambiguous') return { valid: false, reason: 'say which chain, like "on base" or "on ethereum"', needs: 'chain' };
    if (!found) return { valid: false, reason: 'not an address Pip knows' };
    chain = found;
  }
  if (tagRaw && chain !== 'xrp') return { valid: false, reason: 'only XRP payments take a destination tag' };
  const a = checkAddress(chain, recipient);
  if (!a.ok) return { valid: false, reason: a.reason };

  let from: Origin | null = null;
  if (fromRaw) {
    const f = fromRaw.toUpperCase();
    if (!(f in ORIGINS)) return { valid: false, reason: 'Pip can pay from NEAR, USDC or USDT' };
    from = f as Origin;
  }
  // Same token on NEAR from the same token: the plain NEAR flow (/v1/pay/intents), no swap.
  const plain = chain === 'near' && (token === 'NEAR' || token === 'USDC') && (from === null || from === token);
  return { valid: true, kind: plain ? 'near' : 'xchain', amount, token, chain, recipient, from, tag: tagRaw ?? null };
}

export const chainName = (id: string) => CHAINS[id]?.name ?? id;

const NO_SWAP = 'no swap found; try "swap 1 near to usdc"';
export type SwapParse = { valid: true; kind: 'swap'; amount: string; from: Origin; token: string; chain: string } | { valid: false; reason: string };
// "swap 1 near to usdc", "convert 0.5 near into usdc", "swap 10 usdc to eth on base". The origin is always in the user's NEAR wallet.
const SWAP = new RegExp(String.raw`\b(?:swap|convert|exchange|trade)\s+(?:my\s+)?(\S+?)\s*([a-z][a-z0-9]{1,9})(?:\s+on\s+near)?\s+(?:to|into|for)\s+([a-z][a-z0-9]{1,9})${ON}${END}`, 'gi');

/** Reads one swap from the user's NEAR wallet: to a NEAR token (own account) or to a token on another chain (own saved address). */
export function parseSwap(text: string): SwapParse {
  const found = [...dollarsAsUnit(text).matchAll(SWAP)];
  if (found.length === 0) return { valid: false, reason: NO_SWAP };
  if (found.length > 1) return { valid: false, reason: 'more than one swap in the text; do one at a time' };
  const [, amountRaw, fromRaw, toRaw, onRaw] = found[0];
  const amount = cleanAmount(amountRaw);
  if (!amount) return { valid: false, reason: BAD_AMOUNT };
  const f = fromRaw.toUpperCase() === 'WNEAR' ? 'NEAR' : fromRaw.toUpperCase();
  if (!(f in ORIGINS)) return { valid: false, reason: 'Pip can swap from NEAR, USDC or USDT in your wallet' };
  const chain = onRaw ? chainByName(onRaw) : 'near';
  if (!chain) return { valid: false, reason: `Pip does not swap to ${onRaw} yet` };
  // On NEAR, Pip's own account holds wrapped NEAR as wNEAR: "to near" is wNEAR there.
  const token = chain === 'near' && toRaw.toUpperCase() === 'NEAR' ? 'WNEAR' : toRaw.toUpperCase();
  if (chain === 'near' && (token === f || (token === 'WNEAR' && f === 'NEAR'))) return { valid: false, reason: 'that is the same token; pick another one' };
  return { valid: true, kind: 'swap', amount, from: f as Origin, token, chain };
}

const NO_REQUEST = 'no request found; try "request 5 usdc on base"';
export type RequestParse =
  | { valid: true; kind: 'request' | 'topup'; amount: string; token: 'USDC' | 'USDT'; chain: string }
  | { valid: false; kind?: 'request' | 'topup'; reason: string; needs?: 'chain' | 'amount'; amount?: string; token?: string; chain?: string };
// "request 5 usdc on base", "ask ana for 5 usdc on base", "top up my pip with 20 usdc from base". The payer pays on that chain.
const REQUEST = new RegExp(String.raw`\b(?:request|ask\s+(?:@?[a-z0-9_.-]+\s+)?for|charge\s+@?[a-z0-9_.-]+)\s+(\S+?)\s*([a-z][a-z0-9]{1,9})(?:\s+from\s+@?([a-z0-9_.-]+))?${ON}${END}`, 'gi');
const TOPUP = new RegExp(String.raw`\btop\s*-?\s*up\s+(?:my\s+)?(?:pip|wallet)(?:\s+wallet)?(?:\s+with\s+(\S+?)\s*([a-z][a-z0-9]{1,9}))?(?:\s+(?:from|on|via)\s+(?:the\s+)?([a-z]+)(?:\s+(?:chain|network))?)?${END}`, 'gi');

/** Reads a request for money from someone on another chain, or a top-up of the user's own Pip wallet. Pip never moves money here. */
export function parseRequest(text: string): RequestParse {
  const t = dollarsAsUnit(text);
  const top = [...t.matchAll(TOPUP)];
  const req = top.length ? [] : [...t.matchAll(REQUEST)];
  const all = top.length ? top : req;
  if (all.length === 0) return { valid: false, reason: NO_REQUEST };
  if (all.length > 1) return { valid: false, reason: 'more than one request in the text; ask for one at a time' };
  const kind = top.length ? 'topup' : 'request';
  // "request 5 usdc from base": a chain after "from" is the chain; any other word is the payer's name.
  const [, amountRaw, tokenRaw, a3, a4] = all[0];
  const onRaw = top.length ? a3 : a4 ?? (a3 && chainByName(a3) ? a3 : undefined);
  const named = onRaw ? chainByName(onRaw) : null;
  if (!amountRaw) return { valid: false, kind, reason: 'say how much, like "top up my pip with 20 usdc from base"', needs: 'amount', ...(named ? { chain: named } : {}) };
  const amount = cleanAmount(amountRaw);
  if (!amount) return { valid: false, kind, reason: BAD_AMOUNT };
  const token = tokenRaw.toUpperCase();
  if (token !== 'USDC' && token !== 'USDT') return { valid: false, kind, reason: 'Pip can ask for USDC or USDT' };
  if (!onRaw) return { valid: false, kind, reason: kind === 'topup' ? 'Which chain will you pay from?' : 'Which chain will they pay from?', needs: 'chain', amount, token };
  const chain = named;
  if (!chain) return { valid: false, kind, reason: `Pip does not take payments from ${onRaw} yet` };
  if (chain === 'near') return { valid: false, kind, reason: 'on NEAR, share your Pip account instead' };
  return { valid: true, kind, amount, token, chain };
}

/** The one reading the keyboard uses: a payment, else a swap, else a request or top-up. */
export function parseAny(text: string): XchainParse | SwapParse | RequestParse {
  const pay = parseXchain(text);
  if (pay.valid || !pay.reason.startsWith('no payment found')) return pay;
  const swap = parseSwap(text);
  if (swap.valid || swap.reason !== NO_SWAP) return swap;
  const req = parseRequest(text);
  return req.valid || req.reason !== NO_REQUEST ? req : pay;
}
