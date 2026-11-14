// A live NEAR Intents quote from the command line. No keys, no wallet, no money moves (a 1Click "dry" quote).
// npm run quote -- "send 5 usdc to 0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045 on base"
import { findOrigin, findToken } from '../src/pay/xchain/assets.ts';
import { quoteRequest, typedUnits } from '../src/pay/xchain/check.ts';
import { chainName, parseXchain } from '../src/pay/xchain/parse.ts';
import { checkPin } from '../src/pay/xchain/pins.ts';
import { createOneClick } from '../src/pay/xchain/sources.ts';
import { fromBase } from '../src/pay/xchain/units.ts';

const text = process.argv.slice(2).join(' ') || 'send 5 usdc to 0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045 on base';
const fail = (m: string): never => { console.error(`Stopped: ${m}`); process.exit(1); };

console.log(`Typed: "${text}"`);
const p = parseXchain(text);
if (!p.valid) fail(p.reason);
if (p.valid && p.kind !== 'xchain') fail('that is a plain NEAR payment, not a cross-chain one; name another chain, like "on base"');
if (!p.valid) process.exit(1);

const oneClick = createOneClick();
const list = await oneClick.tokens();
const destFound = findToken(list, p.token, p.chain);
if (!destFound.ok) fail(destFound.reason);
const dest = (destFound as { ok: true; token: (typeof list)[number] }).token;
const pin = checkPin(dest);
if (!pin.ok) fail(`${dest.symbol} on ${chainName(dest.blockchain)} has no verified contract pin: ${pin.reason}`);
const origin = findOrigin(list, p.from ?? 'USDC') ?? fail('origin token missing from the 1Click list');

const units = typedUnits(p.amount, 'exact_out', origin, dest);
if (!units.ok) fail(units.reason);
const typed = (units as { ok: true; units: bigint }).units;

const req = quoteRequest({
  mode: 'exact_out', units: typed, origin, dest, recipient: p.recipient, refundTo: /* any implicit account; a dry quote never refunds */ '46b2c7240a82eca89381c5ff4070c6e6465e23fa2acb9d679fe009b4739900c8',
  deadline: new Date(Date.now() + 10 * 60_000), slippageBps: 100, dry: true,
});
const q = await oneClick.quote(req);
const x = q.quote;

console.log(`Contract pin:  ${dest.symbol} on ${chainName(dest.blockchain)} matches Pip's verified pin`);
console.log(`Decimals:      ${origin.symbol} on NEAR = ${origin.decimals}, ${dest.symbol} on ${chainName(dest.blockchain)} = ${dest.decimals}`);
console.log(`They get:      ${fromBase(BigInt(x.amountOut), dest.decimals)} ${dest.symbol}  (${x.amountOut} base units, exact)`);
console.log(`You pay:       ${fromBase(BigInt(x.amountIn), origin.decimals)} ${origin.symbol} from your NEAR wallet  (${x.amountIn} base units)`);
console.log(`Route:         NEAR Intents 1Click, about ${x.timeEstimate} s`);
console.log(`Exact amount:  ${BigInt(x.amountOut) === typed && BigInt(x.minAmountOut) === typed ? 'yes, 1Click delivers exactly what you typed' : 'NO, Pip would refuse this quote'}`);
console.log('Dry quote: no deposit address, nothing signed, no money moved.');
