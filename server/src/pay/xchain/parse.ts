import { CHAINS, ORIGINS, addressKind, chainByName, checkAddress, type Origin } from './assets.ts';

export type XchainPayment = { amount: string; token: string; chain: string; recipient: string; from: Origin | null };
export type XchainParse =
  | ({ valid: true; kind: 'near' | 'xchain' } & XchainPayment)
  | { valid: false; reason: string };

const VERB = String.raw`(?:send|pay|transfer|give)`;
const ON = String.raw`(?:\s+(?:on|via)\s+(?:the\s+)?([a-z]+)(?:\s+(?:chain|network))?)?`;
const FROM = String.raw`(?:\s+from\s+(?:my\s+)?([a-z]+)(?:\s+(?:wallet|balance|account))?)?`;
const END = String.raw`(?=[\s,;!?]|\.(?:\s|$)|$)`;
// "send 20 USDT on solana to <addr> from my NEAR", "pay 0.01 ETH to 0x… on base". One shape; nothing is guessed.
const SHAPE = new RegExp(String.raw`\b${VERB}\s+(\S+?)\s*([a-z][a-z0-9]{1,9})${ON}\s+to\s+(@?[^\s,;!?]+?)${ON}${FROM}${END}`, 'gi');

/** Reads one any-token, any-chain payment from a line of text. Pure: no network. Decimals are checked later against the token list. */
export function parseXchain(text: string): XchainParse {
  const found = [...text.matchAll(SHAPE)];
  if (found.length === 0) return { valid: false, reason: 'no payment found; try "send 5 USDC to 0x… on base"' };
  if (found.length > 1) return { valid: false, reason: 'more than one payment in the text; send one at a time' };
  const [, amountRaw, tokenRaw, on1, targetRaw, on2, fromRaw] = found[0];
  if (!/^\d{1,12}(\.\d{1,30})?$/.test(amountRaw) || !/[1-9]/.test(amountRaw)) return { valid: false, reason: 'write the amount as a plain number above zero, like 5 or 0.5' };
  const amount = amountRaw.includes('.') ? amountRaw.replace(/\.?0+$/, '').replace(/^0+(?=\d)/, '') : amountRaw.replace(/^0+(?=\d)/, '');
  const token = tokenRaw.toUpperCase();
  const recipient = targetRaw.replace(/^@/, '').replace(/\.$/, '');

  const named = [on1, on2].filter(Boolean).map((n) => ({ raw: n!, id: chainByName(n!) }));
  const bad = named.find((n) => !n.id);
  if (bad) return { valid: false, reason: `Pip does not pay to ${bad.raw} yet` };
  if (named.length === 2 && named[0].id !== named[1].id) return { valid: false, reason: 'two different chains named; name one' };
  let chain = named[0]?.id ?? null;
  if ((chain === null || chain === 'near') && recipient !== recipient.toLowerCase() && addressKind(recipient.toLowerCase()) === 'near') return { valid: false, reason: 'NEAR account ids are lower case' };
  if (!chain) {
    const kind = addressKind(recipient);
    if (kind === 'evm') return { valid: false, reason: 'say which chain, like "on base" or "on ethereum"' };
    if (!kind) return { valid: false, reason: 'not an address Pip knows' };
    chain = kind === 'sol' ? 'sol' : kind === 'tron' ? 'tron' : 'near';
  }
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
  return { valid: true, kind: plain ? 'near' : 'xchain', amount, token, chain, recipient, from };
}

export const chainName = (id: string) => CHAINS[id]?.name ?? id;
