import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash, generateKeyPairSync, sign, type KeyObject } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { Transaction, baseEncode } from 'near-api-js';
import { setup } from './helpers.ts';
import { payConfig } from '../src/pay/config.ts';
import { mainnetConfig } from '../src/pay/network.ts';
import type { PhoneChain } from '../src/pay/phone/chain.ts';
import { ORIGINS, checkAddress, findToken, type TokenRow } from '../src/pay/xchain/assets.ts';
import { PINS, checkPin } from '../src/pay/xchain/pins.ts';
import { convertBits } from '../src/pay/xchain/addresses.ts';
import { keccak256 } from '../src/pay/xchain/eip55.ts';
import { agreedPrice, checkQuote, defaultLimits, quoteRequest, typedUnits, type Prices } from '../src/pay/xchain/check.ts';
import { parseAny, parseRequest, parseSwap, parseXchain } from '../src/pay/xchain/parse.ts';
import { mapStatus, requestStatus } from '../src/pay/xchain/routes.ts';
import { type OneClick, type OneClickQuote, type OneClickStatus, type PriceSource } from '../src/pay/xchain/sources.ts';
import { buildDeposit } from '../src/pay/xchain/tx.ts';
import { approvalMessage, sha256 } from '../src/pay/phone/tx.ts';
import { diffBps, fromBase, parsePrice, toBase, usdText, usdValue } from '../src/pay/xchain/units.ts';

const TOKENS = JSON.parse(readFileSync(new URL('./fixtures/oneclick-tokens.json', import.meta.url), 'utf8')) as TokenRow[];
const DRY_IN = JSON.parse(readFileSync(new URL('./fixtures/oneclick-dry-quote.json', import.meta.url), 'utf8')) as OneClickQuote;
const DRY_OUT = JSON.parse(readFileSync(new URL('./fixtures/oneclick-dry-quote-exact-out.json', import.meta.url), 'utf8')) as OneClickQuote;
const tok = (symbol: string, chain: string) => { const r = findToken(TOKENS, symbol, chain); assert.ok(r.ok, `${symbol} ${chain}`); return r.token; };
const SOL_ADDR = 'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v';
const TRON_ADDR = 'TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t';
const EVM = '0xd8da6bf26964af9d7eed9e10c19b4ae4ff1b9da3';
const BLOCK = 'GJ8ThW5tGmvBbGr8Kto6Ahtv1mhK5cXhkRMdNsJxbVkK';
const DEPOSIT = 'ab'.repeat(32);
const EVM_DEPOSIT = '0x' + '7a'.repeat(20);

// ---- parse
test('xchain parse: "$" with a dollar stablecoin is the unit; the chain comes from the address; 0x asks which chain', () => {
  const read = (text: string) => parseXchain(text) as Record<string, unknown>;
  for (const [text, amount, token, chain] of [
    [`send $0.02 USDT to ${TRON_ADDR}`, '0.02', 'USDT', 'tron'],
    [`send 0.02 usdt to ${TRON_ADDR}`, '0.02', 'USDT', 'tron'],
    [`send $5 to ${SOL_ADDR}`, '5', 'USDC', 'sol'],
    [`send 5 bucks of usdc to ${SOL_ADDR}`, '5', 'USDC', 'sol'],
    ['send $ 3 usdc to ana.near', '3', 'USDC', 'near'],
  ] as const) {
    const r = read(text);
    assert.equal(r.valid, true, `${text}: ${r.reason}`);
    assert.deepEqual([r.amount, r.token, r.chain], [amount, token, chain], text);
  }
  const evm = read(`send $0.02 USDT to ${EVM}`);
  assert.equal(evm.valid, false);
  assert.equal(evm.needs, 'chain');
  assert.equal(read(`send $5 ETH to ${EVM} on base`).valid, false);
});

test('xchain parse: 24 cases', () => {
  const ok = (text: string, want: Record<string, unknown>) => {
    const r = parseXchain(text);
    assert.ok(r.valid, `${text}: ${!r.valid && r.reason}`);
    for (const [k, v] of Object.entries(want)) assert.equal((r as Record<string, unknown>)[k], v, `${text} ${k}`);
  };
  const bad = (text: string, reason: RegExp) => {
    const r = parseXchain(text);
    assert.equal(r.valid, false, text);
    assert.match((r as { reason: string }).reason, reason, text);
  };
  ok(`send 5 USDC to ${EVM} on base`, { kind: 'xchain', amount: '5', token: 'USDC', chain: 'base', recipient: EVM, from: null });
  ok(`send 10 USDT to ${SOL_ADDR}`, { chain: 'sol', token: 'USDT', amount: '10' });
  ok('pay 5 usdc to ana.near', { kind: 'near', chain: 'near', token: 'USDC' });
  ok('send 1 NEAR to ana.near', { kind: 'near' });
  ok(`send 20 USDT on solana to ${SOL_ADDR} from my NEAR`, { chain: 'sol', from: 'NEAR', token: 'USDT', amount: '20' });
  ok(`pay 0.01 ETH on base to ${EVM}`, { chain: 'base', token: 'ETH', amount: '0.01' });
  ok('send 50 USDC to ana.near from my NEAR', { kind: 'xchain', chain: 'near', from: 'NEAR' });
  ok('send 5 USDT to ana.near', { kind: 'xchain', chain: 'near', token: 'USDT' });
  ok(`send 7 USDT to ${TRON_ADDR}`, { chain: 'tron' });
  ok(`transfer 2.50 usdc to ${EVM} on arbitrum`, { chain: 'arb', amount: '2.5' });
  ok(`give 0.000001 USDC to ${EVM} on the polygon network`, { chain: 'pol', amount: '0.000001' });
  ok(`please send 3 usdc to ${EVM} via ethereum, thanks`, { chain: 'eth' });
  ok(`send 1 SOL to ${SOL_ADDR} on solana from usdc`, { chain: 'sol', from: 'USDC' });
  ok(`send 005 USDC to ${EVM} on bsc`, { amount: '5', chain: 'bsc' });
  bad(`send 5 USDC to ${EVM}`, /say which chain/);
  bad(`send 5 USDC to ${EVM} on dogechain`, /does not pay to dogechain/);
  bad(`send 5 USDC to ${EVM} on base`.replace(EVM, '0x1234'), /not a Base address/);
  bad(`send 5 USDC to ${SOL_ADDR} on base`, /not a Base address/);
  bad(`send 5 USDT to ${TRON_ADDR.slice(0, -1)}u`, /not an address|not a Tron/);
  bad('send 5 USDC to Ana.near', /lower case/);
  bad(`send 5 USDC on base to ${EVM} on solana`, /two different chains/);
  bad(`send 5 USDC to ${EVM} on base from my DOGE`, /pay from NEAR, USDC or USDT/);
  bad(`send 0 USDC to ${EVM} on base`, /above zero/);
  bad(`send 1e3 USDC to ${EVM} on base`, /plain number/);
  bad(`send 1 USDC to ${EVM} on base and send 2 USDC to ${EVM} on base`, /more than one/);
  bad('hello there', /no payment found/);
});

test('xchain address checks per chain', () => {
  assert.ok(checkAddress('base', EVM).ok);
  assert.equal(checkAddress('base', '0x' + '0'.repeat(40)).ok, false, 'the zero address is refused');
  assert.ok(checkAddress('sol', SOL_ADDR).ok);
  assert.equal(checkAddress('sol', SOL_ADDR.slice(0, 20)).ok, false);
  assert.ok(checkAddress('tron', TRON_ADDR).ok);
  assert.equal(checkAddress('tron', TRON_ADDR.replace('Z', 'Y')).ok, false, 'a bad Tron checksum is refused');
  assert.ok(checkAddress('near', 'ana.near').ok);
  assert.equal(checkAddress('near', 'ana.testnet').ok, false);
});

// ---- golden numbers
test('xchain units: golden decimals, rounding never silent, dust', () => {
  const g: [string, number, string][] = [
    ['5', 6, '5000000'], ['0.000001', 6, '1'], ['10.5', 6, '10500000'], // USDC / USDT
    ['1', 24, '1000000000000000000000000'], ['0.000000000000000000000001', 24, '1'], // NEAR / wNEAR, 1 yocto
    ['1.520721912852309794299592', 24, '1520721912852309794299592'],
    ['0.01', 18, '10000000000000000'], ['1', 18, '1000000000000000000'], // ETH, USDC on BNB
    ['0.5', 9, '500000000'], ['0.000000001', 9, '1'], // SOL
    ['0.00000001', 8, '1'], ['21000000', 8, '2100000000000000'], // BTC
    ['5.000000', 6, '5000000'], ['5.0', 6, '5000000'],
  ];
  for (const [text, d, units] of g) {
    assert.equal(toBase(text, d), BigInt(units), `${text} @${d}`);
    assert.equal(toBase(fromBase(BigInt(units), d), d), BigInt(units), `round trip ${units} @${d}`);
  }
  assert.equal(toBase('0.0000001', 6), null, 'USDC dust below 1 unit is refused, not rounded');
  assert.equal(toBase('0.0000000000000000000000001', 24), null, 'below 1 yoctoNEAR is refused');
  assert.equal(toBase('0.000000001', 8), null, 'BTC 9 decimals is refused');
  assert.equal(toBase('1,5', 6), null);
  assert.equal(toBase('-1', 6), null);
  assert.equal(toBase('1e6', 6), null);
  assert.equal(fromBase(1n, 24), '0.000000000000000000000001');
  assert.equal(fromBase(5000000n, 6), '5');
  assert.equal(parsePrice(2.79), 2_790_000_000_000n);
  assert.equal(parsePrice('1.2e-7'), 120_000n);
  assert.equal(parsePrice('0'), null);
  assert.equal(parsePrice('abc'), null);
  // 5 USDC at $0.999685 is $4.998425 (micro-dollars, rounded down).
  assert.equal(usdText(usdValue(5_000_000n, 6, parsePrice(0.999685)!)), '4.998425');
  // 1.5 NEAR at $3.34 is $5.01; the 24 decimals do not overflow or lose a cent.
  assert.equal(usdText(usdValue(toBase('1.5', 24)!, 24, parsePrice(3.34)!)), '5.01');
  assert.equal(diffBps(102n, 100n), 200n);
  assert.equal(diffBps(1001n, 1000n), 10n);
});

test('xchain typed amount: each side uses its own decimals (USDC on BNB is 18, on Base and NEAR 6)', () => {
  const usdcNear = TOKENS.find((t) => t.assetId === ORIGINS.USDC.assetId)!;
  const bnb = tok('USDC', 'bsc'), base = tok('USDC', 'base');
  assert.equal(bnb.decimals, 18);
  assert.equal(base.decimals, 6);
  assert.deepEqual(typedUnits('5', 'exact_out', usdcNear, bnb), { ok: true, units: 5_000_000_000_000_000_000n });
  assert.deepEqual(typedUnits('5', 'exact_out', usdcNear, base), { ok: true, units: 5_000_000n });
  assert.deepEqual(typedUnits('5', 'exact_in', usdcNear, bnb), { ok: true, units: 5_000_000n }, 'exact_in reads the origin side');
  assert.match((typedUnits('0.0000001', 'exact_out', usdcNear, base) as { reason: string }).reason, /at most 6 decimals/);
  assert.ok(typedUnits('0.0000001', 'exact_out', usdcNear, bnb).ok, 'the same text fits 18 decimals');
  assert.equal(tok('SOL', 'sol').decimals, 9);
  assert.equal(tok('ETH', 'base').decimals, 18);
  assert.equal(TOKENS.find((t) => t.assetId === ORIGINS.NEAR.assetId)!.decimals, 24);
});

// ---- the quote check
const PRICE: Record<string, string> = { 'usd-coin': '0.9997', tether: '0.9994', 'wrapped-near': '3.33', ethereum: '1890', solana: '75.5' };
const twoSources = (t: TokenRow, skew = '1'): Prices => [
  { source: 'coingecko', price: PRICE[t.coingeckoId!] }, { source: 'relay', price: (Number(PRICE[t.coingeckoId!]) * Number(skew)).toString() },
];

function fakeQuote(req: Record<string, unknown>, o: { feeBps?: bigint; now?: number; tweak?: (q: OneClickQuote) => void } = {}): OneClickQuote {
  const oT = TOKENS.find((t) => t.assetId === req.originAsset)!, dT = TOKENS.find((t) => t.assetId === req.destinationAsset)!;
  const pIn = parsePrice(PRICE[oT.coingeckoId!])!, pOut = parsePrice(PRICE[dT.coingeckoId!])!;
  const fee = o.feeBps ?? 10n, slip = BigInt(req.slippageTolerance as number);
  const sIn = 10n ** BigInt(oT.decimals), sOut = 10n ** BigInt(dT.decimals);
  let aIn: bigint, aOut: bigint, minIn: bigint, minOut: bigint;
  if (req.swapType === 'EXACT_OUTPUT') {
    aOut = BigInt(req.amount as string); minOut = aOut;
    aIn = (aOut * pOut * sIn * (10_000n + fee + slip) + pIn * sOut * 10_000n - 1n) / (pIn * sOut * 10_000n);
    minIn = (aIn * (10_000n - slip)) / 10_000n;
  } else {
    aIn = BigInt(req.amount as string); minIn = aIn;
    aOut = (aIn * pIn * sOut * (10_000n - fee)) / (pOut * sIn * 10_000n);
    minOut = (aOut * (10_000n - slip)) / 10_000n;
  }
  const q: OneClickQuote = {
    quote: {
      amountIn: aIn.toString(), amountInFormatted: fromBase(aIn, oT.decimals), amountInUsd: usdText(usdValue(aIn, oT.decimals, pIn)), minAmountIn: minIn.toString(),
      amountOut: aOut.toString(), amountOutFormatted: fromBase(aOut, dT.decimals), amountOutUsd: usdText(usdValue(aOut, dT.decimals, pOut)), minAmountOut: minOut.toString(),
      timeEstimate: 22, ...(req.dry ? {} : { depositAddress: oT.blockchain === 'near' ? DEPOSIT : EVM_DEPOSIT, deadline: new Date((o.now ?? Date.now()) + 30 * 60_000).toISOString() }),
    },
    quoteRequest: { ...req }, signature: 'ed25519:sig', timestamp: new Date().toISOString(), correlationId: 'c-1',
  };
  o.tweak?.(q);
  return q;
}

function judge(o: { mode?: 'exact_out' | 'exact_in'; amount: string; from: keyof typeof ORIGINS; dest: TokenRow; feeBps?: bigint; skew?: string; tweak?: (q: OneClickQuote) => void; chainDecimals?: { origin: number | null; dest: number | null }; list?: (t: TokenRow) => TokenRow; prices?: Prices }) {
  const mode = o.mode ?? 'exact_out';
  const fix = o.list ?? ((t) => t);
  const origin = fix(TOKENS.find((t) => t.assetId === ORIGINS[o.from].assetId)!), dest = fix(o.dest);
  const typed = typedUnits(o.amount, mode, origin, dest);
  assert.ok(typed.ok);
  const now = Date.now();
  const sent = quoteRequest({ mode, units: typed.units, origin, dest, recipient: EVM, refundTo: 'cd'.repeat(32), deadline: new Date(now + 1_800_000), slippageBps: 100, dry: false });
  const q = fakeQuote(sent, { feeBps: o.feeBps, now, tweak: o.tweak });
  return checkQuote({
    mode, typed: typed.units, origin, dest, chainDecimals: o.chainDecimals ?? { origin: o.dest === dest ? origin.decimals : origin.decimals, dest: o.dest.decimals },
    sent, q, prices: { origin: twoSources(origin), dest: o.prices ?? twoSources(dest, o.skew) }, limits: defaultLimits({}), now, minDeadlineMs: 25 * 60_000,
  });
}

test('xchain check: exact output 5 USDC (NEAR, 6) -> USDC on BNB (18): verified, every number exact', () => {
  const v = judge({ amount: '5', from: 'USDC', dest: tok('USDC', 'bsc') });
  assert.ok(v.ok, JSON.stringify(v));
  const n = v.numbers;
  assert.equal(n.amount_out.units, '5000000000000000000');
  assert.equal(n.amount_out.text, '5');
  assert.equal(n.amount_out.decimals, 18);
  assert.equal(n.max_amount_in.decimals, 6);
  // 5 out at equal prices, +10 bps fee +100 bps slippage, rounded up: 5.055 USDC max in.
  assert.equal(n.max_amount_in.units, '5055000');
  assert.equal(n.max_amount_in.text, '5.055');
  assert.equal(n.fee.in_origin.units, '55000');
  assert.equal(n.fee.bps, '109');
  // 5e18 * 1e6 / 5055000 = 989119683481701285.86…, floored: a shown rate never overstates.
  assert.equal(n.rate.one, '0.989119683481701285');
});

test('xchain check: exact output from NEAR (24) -> 0.01 ETH on Base (18), and SOL (9)', () => {
  const eth = judge({ amount: '0.01', from: 'NEAR', dest: tok('ETH', 'base') });
  assert.ok(eth.ok, JSON.stringify(eth));
  assert.equal(eth.numbers.amount_out.units, '10000000000000000');
  assert.equal(eth.numbers.max_amount_in.decimals, 24);
  assert.equal(BigInt(eth.numbers.max_amount_in.units) > 5_000_000_000_000_000_000_000n, true, '0.01 ETH costs over 5 NEAR');
  const sol = judge({ amount: '0.5', from: 'USDT', dest: tok('SOL', 'sol') });
  assert.ok(sol.ok);
  assert.equal(sol.numbers.amount_out.units, '500000000');
});

test('xchain check: exact input 0.000001 USDC dust still adds up', () => {
  const v = judge({ mode: 'exact_in', amount: '0.000001', from: 'USDC', dest: tok('USDC', 'base') });
  // 1 unit in, 0 out after fees: refused, never a zero-output payment.
  assert.equal(v.ok, false);
  assert.match((v as { refused: string }).refused, /bad amountOut/);
  const two = judge({ mode: 'exact_in', amount: '0.01', from: 'USDC', dest: tok('USDC', 'base') });
  assert.ok(two.ok, JSON.stringify(two));
  assert.equal(two.numbers.amount_out.units, '9990', '10000 units less 10 bps');
});

test('xchain check: the recorded live dry quotes pass the shape and decimals checks', () => {
  const usdc = TOKENS.find((t) => t.assetId === ORIGINS.USDC.assetId)!, wnear = TOKENS.find((t) => t.assetId === ORIGINS.NEAR.assetId)!, base = tok('USDC', 'base');
  for (const [q, origin, mode, typed] of [[DRY_IN, usdc, 'exact_in', 5_000_000n], [DRY_OUT, wnear, 'exact_out', 5_000_000n]] as const) {
    const sent = { ...q.quoteRequest };
    const prices = { origin: [{ source: 'coingecko', price: origin.price }, { source: 'relay', price: origin.price }], dest: [{ source: 'coingecko', price: base.price }, { source: 'relay', price: base.price }] };
    const v = checkQuote({ mode, typed, origin, dest: base, chainDecimals: { origin: origin.decimals, dest: 6 }, sent, q, prices, limits: defaultLimits({}), now: Date.now(), minDeadlineMs: 0 });
    assert.ok(v.ok, `${mode}: ${JSON.stringify(v)}`);
  }
});

test('xchain check: wrong decimals are refused (token list vs chain, and in the quote itself)', () => {
  const base = tok('USDC', 'base');
  const listSays18 = judge({ amount: '5', from: 'USDC', dest: base, list: (t) => (t === base ? { ...t, decimals: 18 } : t), chainDecimals: { origin: 6, dest: 6 } });
  assert.equal(listSays18.ok, false);
  assert.match((listSays18 as { refused: string }).refused, /decimals differ: token list 18, chain 6/);
  const unreadable = judge({ amount: '5', from: 'USDC', dest: base, chainDecimals: { origin: 6, dest: null } });
  assert.match((unreadable as { refused: string }).refused, /could not read/);
  const quoteWrong = judge({ amount: '5', from: 'USDC', dest: base, tweak: (q) => { q.quote.amountInFormatted = fromBase(BigInt(q.quote.amountIn), 18); } });
  assert.match((quoteWrong as { refused: string }).refused, /does not fit 6 decimals/);
});

test('xchain check: refusals for fee, rate, echo, exactness, deadline, memo; one price source is not verified', () => {
  const base = tok('USDC', 'base');
  const r = (o: Partial<Parameters<typeof judge>[0]>) => judge({ amount: '5', from: 'USDC', dest: base, ...o });
  assert.match((r({ feeBps: 350n }) as { refused: string }).refused, /fee is .* bps/);
  assert.match((r({ amount: '100', feeBps: 150n }) as { refused: string }).refused, /fee is \$/, '$1 cap on a $100 payment');
  assert.match((r({ tweak: (q) => { q.quote.amountOutUsd = '5.2'; } }) as { refused: string }).refused, /rate is more than 200 bps/);
  assert.match((r({ tweak: (q) => { q.quoteRequest.recipient = '0x' + '1'.repeat(40); } }) as { refused: string }).refused, /\(recipient\)/);
  assert.match((r({ tweak: (q) => { q.quote.amountOut = '4999999'; q.quote.amountOutFormatted = '4.999999'; } }) as { refused: string }).refused, /exact amount typed|minimums/);
  assert.match((r({ tweak: (q) => { q.quote.deadline = new Date(Date.now() + 60_000).toISOString(); } }) as { refused: string }).refused, /deadline/);
  assert.match((r({ tweak: (q) => { q.quote.depositMemo = '123'; } }) as { refused: string }).refused, /memo/);
  assert.match((r({ tweak: (q) => { q.quote.depositAddress = '0xabc'; } }) as { refused: string }).refused, /deposit account/);
  const spread = r({ skew: '1.05' });
  assert.equal(spread.ok, false);
  assert.equal((spread as { refused: unknown }).refused, null);
  assert.match((spread as { not_verified: string[] }).not_verified[0], /differ by more than 200 bps/);
  const one = r({ prices: [{ source: 'coingecko', price: '1' }, { source: 'relay', price: null }] });
  assert.equal(one.verified, false);
  assert.match((one as { not_verified: string[] }).not_verified[0], /only 1 price source/);
  assert.equal(agreedPrice([{ source: 'coingecko', price: '1' }, { source: '1click', price: '1.019' }], 200n).ok, true);
});

test('xchain status mapping', () => {
  assert.equal(mapStatus('pending'), 'awaiting_signature');
  assert.equal(mapStatus('built'), 'awaiting_signature');
  assert.equal(mapStatus('expired'), 'expired');
  assert.equal(mapStatus('failed', 'SUCCESS'), 'not_sent', 'a failed broadcast never reads as delivered');
  for (const [oc, want] of [['PENDING_DEPOSIT', 'waiting_for_deposit'], ['KNOWN_DEPOSIT_TX', 'deposit_seen'], ['INCOMPLETE_DEPOSIT', 'incomplete_deposit'], ['PROCESSING', 'swapping'], ['SUCCESS', 'delivered'], ['REFUNDED', 'refunded'], ['FAILED', 'failed']] as const) {
    assert.equal(mapStatus('sent', oc), want);
    assert.equal(mapStatus('outcome_unknown', oc), want);
  }
  assert.equal(mapStatus('sent', null), 'checking');
});

test('xchain deposit tx: wrap NEAR, register storage, exact ft_transfer to the deposit account', () => {
  const pk = new Uint8Array(32).fill(7);
  const plan = { signerId: 'cd'.repeat(32), publicKey: pk, nonce: 9n, blockHash: BLOCK, contract: 'wrap.near', depositAddress: DEPOSIT, units: 1_520_721_912_852_309_794_299_592n, wrap: true, signerStorage: 1_250_000_000_000_000_000_000n, depositStorage: 1_250_000_000_000_000_000_000n };
  const tx = Transaction.decode(buildDeposit(plan).bytes);
  assert.equal(tx.receiverId, 'wrap.near');
  const calls = tx.actions.map((a) => ({ m: a.functionCall!.methodName, args: JSON.parse(Buffer.from(a.functionCall!.args).toString()), dep: a.functionCall!.deposit }));
  assert.deepEqual(calls.map((c) => c.m), ['storage_deposit', 'storage_deposit', 'near_deposit', 'ft_transfer']);
  assert.equal(calls[0].args.account_id, plan.signerId);
  assert.equal(calls[1].args.account_id, DEPOSIT);
  assert.equal(calls[2].dep, plan.units);
  assert.deepEqual(calls[3].args, { receiver_id: DEPOSIT, amount: '1520721912852309794299592' });
  assert.equal(calls[3].dep, 1n);
  const usdt = Transaction.decode(buildDeposit({ ...plan, contract: 'usdt.tether-token.near', wrap: false, units: 5_000_000n, depositStorage: null }).bytes);
  assert.equal(usdt.receiverId, 'usdt.tether-token.near');
  assert.deepEqual(usdt.actions.map((a) => a.functionCall!.methodName), ['ft_transfer']);
});

// ---- the routes, with a fake 1Click, fake prices, fake decimals and a fake NEAR RPC
function fakeChain(): { chain: PhoneChain; sent: Uint8Array[] } {
  const sent: Uint8Array[] = [];
  return {
    sent,
    chain: {
      async accountExists() { return true; }, async accessKeyNonce() { return 100n; }, async recentBlockHash() { return BLOCK; },
      async storageRegistered() { return true; }, async storageMin() { return 1n; }, async balances() { return { NEAR: 0n, USDC: 0n }; },
      async broadcast(b) { sent.push(b); return 'ok'; },
      async fund() { return 'FundTx'; },
    },
  };
}

function world(o: { mainnet?: boolean; feeBps?: bigint; relayDown?: boolean; tokens?: TokenRow[]; balance?: bigint } = {}) {
  let feeBps = o.feeBps;
  let clock = Date.parse('2026-11-14T15:00:00Z');
  const now = () => clock;
  const fake = fakeChain();
  const quotes: Record<string, unknown>[] = [];
  const deposits: unknown[] = [];
  let ocStatus: OneClickStatus['status'] = 'PROCESSING';
  let statusOverride: OneClickStatus | null = null;
  const oneclick: OneClick = {
    async tokens() { return o.tokens ?? TOKENS; },
    async quote(req) {
      quotes.push(req);
      const n = quotes.length;
      return fakeQuote(req, { feeBps, now: clock, tweak: (q) => { if (q.quote.depositAddress === DEPOSIT && n > 1) q.quote.depositAddress = 'ef'.repeat(32); } });
    },
    async status() { if (statusOverride) return statusOverride; return { status: ocStatus, swapDetails: { destinationChainTxHashes: ocStatus === 'SUCCESS' ? [{ hash: '0xdead', explorerUrl: 'https://basescan.org/tx/0xdead' }] : [] } }; },
    async submitDeposit(b) { deposits.push(b); },
  };
  const prices: PriceSource[] = [
    { name: 'coingecko', price: async (_t, pin) => PRICE[pin.coingeckoId] ?? null },
    { name: 'relay', price: async (_t, pin) => (o.relayDown ? null : PRICE[pin.coingeckoId] ?? null) },
  ];
  const registered = new Set<string>();
  const views = { async storageRegistered(_c: string, a: string) { return registered.has(a); }, async storageMin() { return 1_250_000_000_000_000_000_000n; }, async accountExists(a: string) { return a === 'ana.near'; },
    async balance(c: string | null, a: string) { balanceReads.push({ c, a }); return o.balance ?? 10n ** 30n; } };
  const balanceReads: { c: string | null; a: string }[] = [];
  const mainnet = { ...mainnetConfig, enabled: o.mainnet ?? true };
  const s = setup({ now, pay: { config: { ...payConfig, funderAccountId: 'pipfund.testnet', funderSecretKey: 'ed25519:x' }, phone: { chains: { testnet: fake.chain, mainnet: fake.chain }, mainnet }, xchain: { oneclick, prices, chainDecimals: async (t) => t.decimals, views, limits: defaultLimits({}) } } });
  const { token } = s.device();
  const { publicKey, privateKey } = generateKeyPairSync('ed25519');
  const keyHex = Buffer.from(publicKey.export({ format: 'jwk' }).x!, 'base64url').toString('hex');
  let approver = '';
  const call = (method: string, path: string, body?: unknown, app = false) => s.call(token, method, path, body, app ? { 'x-pay-approver': approver } : {});
  const start = async (network: 'testnet' | 'mainnet' = 'mainnet') => {
    approver = (await (await call('POST', '/v1/pay/approver')).json()).approver_key;
    if (network === 'mainnet') assert.equal((await call('PUT', '/v1/pay/network', { network }, true)).status, 200);
    assert.equal((await call('POST', '/v1/pay/register', { publicKey: keyHex }, true)).status, 200);
  };
  const signHash = (hex: string, k: KeyObject = privateKey) => sign(null, Buffer.from(hex, 'hex'), k).toString('base64');
  return { s, token, privateKey, fake, call, start, quotes, deposits, balanceReads, setOcStatus: (st: OneClickStatus) => { statusOverride = st; }, keyHex, signHash, tick: (ms: number) => { clock += ms; }, setFee: (f: bigint) => { feeBps = f; }, setStatus: (st: OneClickStatus['status']) => { ocStatus = st; } };
}

const quoteBody = { amount: '5', token: 'USDC', chain: 'base', recipient: EVM };

test('xchain preview: on testnet a real dry quote shows the full card; no intent, no deposit address, nothing to sign', async () => {
  const t = world();
  await t.start('testnet');
  const r = await t.call('POST', '/v1/pay/xchain/quote', quoteBody);
  assert.equal(r.status, 200, await r.clone().text());
  const q = await r.json();
  assert.equal(q.preview, true);
  assert.equal(q.preview_reason, 'testnet');
  assert.equal(q.verified, true, 'every check still ran');
  assert.equal(q.intent, null);
  assert.equal(q.deposit_address, undefined);
  assert.equal(q.numbers.amount_out.text, '5');
  assert.equal(q.numbers.max_amount_in.text, '5.055');
  assert.equal(q.action, 'Switch to Mainnet and add 5.055 USDC to send');
  assert.equal(q.slippage_bps, 100);
  assert.deepEqual(q.route_path, ['USDC in your NEAR wallet', 'NEAR Intents solvers', 'USDC on Base']);
  assert.equal(t.quotes.length, 1);
  assert.equal(t.quotes[0].dry, true, 'a preview only ever asks for a dry quote');
  assert.equal(t.quotes[0].refundTo, t.keyHex, 'the implicit id is the same on mainnet');
  assert.equal(t.balanceReads.length, 0);
  const hist = await (await t.call('GET', '/v1/pay/history')).json();
  assert.equal(hist.payments.length, 0, 'no phone intent, so no /unsigned or /submit can reach it');
  // No Pip Pay key at all: nothing to preview with.
  const off = world({ mainnet: false });
  const none = await off.call('POST', '/v1/pay/xchain/quote', quoteBody);
  assert.equal(none.status, 409);
  assert.match((await none.json()).error, /set up Pip Pay/);
  assert.equal(off.quotes.length, 0);
});

test('xchain route: quote -> phone intent -> exact deposit tx -> submit -> deposit notice once -> status', async () => {
  const w = world();
  await w.start();
  const r = await w.call('POST', '/v1/pay/xchain/quote', quoteBody);
  assert.equal(r.status, 201, await r.clone().text());
  const q = await r.json();
  assert.equal(q.verified, true);
  assert.equal(q.destination.chain, 'base');
  assert.equal(q.destination.recipient, EVM);
  assert.equal(q.amount_out.text, '5');
  assert.equal(q.max_amount_in.units, '5055000');
  assert.equal(q.deposit_address, DEPOSIT);
  assert.equal(q.refund_to, w.keyHex);
  assert.ok(q.fee.usd && q.rate.text && q.eta_seconds === 22 && q.route);
  assert.equal(q.intent.recipient, DEPOSIT);
  assert.equal(q.intent.amount, '5.055');
  assert.equal(q.intent.token, 'USDC');
  const sent = w.quotes[0];
  assert.equal(sent.swapType, 'EXACT_OUTPUT');
  assert.equal(sent.amount, '5000000');
  assert.equal(sent.refundTo, w.keyHex);
  assert.equal(sent.originAsset, ORIGINS.USDC.assetId);

  // The plain intent card carries the real destination.
  const card = await (await w.call('GET', `/v1/pay/intents/${q.intent.id}`)).json();
  assert.equal(card.xchain.destination.recipient, EVM);
  assert.equal(card.new_recipient, true);

  const fields = { amount: q.intent.amount, token: q.intent.token, recipient: q.intent.recipient };
  assert.equal((await w.call('POST', `/v1/pay/intents/${q.intent.id}/unsigned`, fields)).status, 403, 'a new destination needs the app key');
  const u = await (await w.call('POST', `/v1/pay/intents/${q.intent.id}/unsigned`, fields, true)).json();
  assert.equal(u.requoted, false, 'a fresh quote is not re-quoted');
  const tx = Transaction.decode(Buffer.from(u.tx_base64, 'base64'));
  assert.equal(tx.receiverId, ORIGINS.USDC.contract);
  assert.equal(tx.signerId, w.keyHex);
  const calls = tx.actions.map((a) => ({ m: a.functionCall!.methodName, args: JSON.parse(Buffer.from(a.functionCall!.args).toString()) }));
  assert.deepEqual(calls.map((c) => c.m), ['storage_deposit', 'ft_transfer']);
  assert.deepEqual(calls[1].args, { receiver_id: DEPOSIT, amount: '5055000' });

  const done = await w.call('POST', `/v1/pay/intents/${q.intent.id}/submit`, { signature: w.signHash(u.sign_hash_hex) });
  assert.equal(done.status, 200);
  assert.equal(w.fake.sent.length, 1);
  const st = await (await w.call('GET', `/v1/pay/xchain/${q.intent.id}`)).json();
  assert.equal(st.status, 'swapping');
  assert.deepEqual(w.deposits, [{ txHash: u.tx_hash, depositAddress: DEPOSIT, nearSenderAccount: w.keyHex }]);
  w.setStatus('SUCCESS');
  w.tick(6_000);
  const st2 = await (await w.call('GET', `/v1/pay/xchain/${q.intent.id}`)).json();
  assert.equal(st2.status, 'delivered');
  assert.equal(st2.delivered_tx[0].hash, '0xdead');
  assert.equal(w.deposits.length, 1, 'the deposit notice goes once');
});

test('xchain route: NEAR origin wraps; the signing window is 2 minutes; an old quote is re-quoted and re-checked before build', async () => {
  const w = world();
  await w.start();
  const body = { amount: '0.5', token: 'USDC', chain: 'base', recipient: EVM, from: 'NEAR' };
  const q = await (await w.call('POST', '/v1/pay/xchain/quote', body)).json();
  assert.equal(q.intent.token, 'NEAR');
  assert.equal(q.max_amount_in.decimals, 24);
  assert.equal(Date.parse(q.intent.expires_at) - Date.parse(q.quote_at), 120_000, 'fix 6: 2-minute window');
  const fields = { amount: q.intent.amount, token: q.intent.token, recipient: q.intent.recipient };
  w.tick(61_000);
  const u = await w.call('POST', `/v1/pay/intents/${q.intent.id}/unsigned`, fields, true);
  assert.equal(u.status, 200, await u.clone().text());
  const ub = await u.json();
  assert.equal(w.quotes.length, 2, 'the old quote was replaced by a fresh one');
  assert.equal(ub.requoted, true);
  assert.notEqual(ub.recipient, q.intent.recipient, 'the deposit account changed');
  // The tx matches the NEW card: receiver contract, deposit account and exact max input all come from the fresh answer.
  {
    const t = Transaction.decode(Buffer.from(ub.tx_base64, 'base64'));
    const ft = JSON.parse(Buffer.from(t.actions.at(-1)!.functionCall!.args).toString());
    assert.equal(ft.receiver_id, ub.recipient);
    assert.equal(ft.receiver_id, ub.xchain.deposit_address);
    assert.equal(ft.amount, ub.xchain.max_amount_in.units);
    assert.equal(ft.amount, toBase(ub.amount, 24)!.toString());
    assert.equal(ub.xchain.max_amount_in.text, ub.amount);
  }
  assert.equal(ub.recipient, 'ef'.repeat(32), 'the tx and card use the new deposit account');
  assert.equal(ub.xchain.deposit_address, 'ef'.repeat(32));
  assert.equal(Date.parse(ub.xchain.quote_at), Date.parse(q.quote_at) + 61_000);
  const tx = Transaction.decode(Buffer.from(ub.tx_base64, 'base64'));
  assert.equal(tx.receiverId, 'wrap.near');
  assert.deepEqual(tx.actions.map((a) => a.functionCall!.methodName), ['storage_deposit', 'storage_deposit', 'near_deposit', 'ft_transfer']);
  assert.equal(tx.actions[2].functionCall!.deposit.toString(), ub.xchain.max_amount_in.units);
  assert.equal(JSON.parse(Buffer.from(tx.actions[3].functionCall!.args).toString()).receiver_id, 'ef'.repeat(32));

  // A re-quote that fails its checks blocks the build.
  const q2 = await (await w.call('POST', '/v1/pay/xchain/quote', body)).json();
  w.setFee(400n);
  w.tick(61_000);
  const bad = await w.call('POST', `/v1/pay/intents/${q2.intent.id}/unsigned`, { amount: q2.intent.amount, token: 'NEAR', recipient: q2.intent.recipient }, true);
  assert.equal(bad.status, 422);
  assert.match((await bad.json()).error, /new quote: the fee is/);
});

test('xchain route: the keyboard approves with a Face ID proof over the intent; first_time turns false after a sent payment', async () => {
  const w = world();
  await w.start();
  const pay = async () => {
    const q = await (await w.call('POST', '/v1/pay/xchain/quote', quoteBody)).json();
    const fields = { amount: q.intent.amount, token: q.intent.token, recipient: q.intent.recipient };
    const proof = sign(null, sha256(approvalMessage({ id: q.intent.id, network: 'mainnet', ...fields })), w.privateKey).toString('base64');
    const u = await w.s.call(w.token, 'POST', `/v1/pay/intents/${q.intent.id}/unsigned`, fields, { 'x-pay-proof': proof });
    assert.equal(u.status, 200, await u.clone().text());
    return { q, u: await u.json() };
  };
  const first = await pay();
  assert.equal(first.q.destination.first_time, true);
  assert.equal(first.u.xchain.destination.first_time, true);
  assert.equal((await w.call('POST', `/v1/pay/intents/${first.q.intent.id}/submit`, { signature: w.signHash(first.u.sign_hash_hex) })).status, 200);
  const second = await pay();
  assert.equal(second.q.destination.first_time, false, 'paid this address on this chain before');
  const other = await (await w.call('POST', '/v1/pay/xchain/quote', { ...quoteBody, chain: 'arb' })).json();
  assert.equal(other.destination.first_time, true, 'the same address on another chain is new');
});

test('xchain route: a named NEAR recipient must exist (fix 3)', async () => {
  const w = world();
  await w.start();
  const typo = await w.call('POST', '/v1/pay/xchain/quote', { amount: '5', token: 'USDT', chain: 'near', recipient: 'typo.near' });
  assert.equal(typo.status, 400);
  assert.match((await typo.json()).error, /typo.near does not exist/);
  assert.equal(w.quotes.length, 0);
  assert.equal((await w.call('POST', '/v1/pay/xchain/quote', { amount: '5', token: 'USDT', chain: 'near', recipient: 'ana.near' })).status, 201);
});

test('xchain route: caps on the max input; not verified makes no intent; dry makes no intent; too many decimals', async () => {
  const w = world();
  await w.start();
  const big = await w.call('POST', '/v1/pay/xchain/quote', { ...quoteBody, amount: '10' });
  assert.equal(big.status, 403, '10 out costs 10.1 in, over the 10 USDC cap');
  assert.match((await big.json()).error, /limit per payment/);
  const dry = await (await w.call('POST', '/v1/pay/xchain/quote', { ...quoteBody, dry: true })).json();
  assert.equal(dry.verified, true);
  assert.equal(dry.intent, null);
  const dec = await w.call('POST', '/v1/pay/xchain/quote', { ...quoteBody, amount: '0.0000001' });
  assert.equal(dec.status, 400);
  assert.match((await dec.json()).error, /at most 6 decimals/);
  const same = await w.call('POST', '/v1/pay/xchain/quote', { amount: '1', token: 'USDC', chain: 'near', recipient: 'ana.near' });
  assert.equal(same.status, 400);

  const u = world({ relayDown: true });
  await u.start();
  const nv = await u.call('POST', '/v1/pay/xchain/quote', quoteBody);
  assert.equal(nv.status, 200);
  const body = await nv.json();
  assert.equal(body.verified, false);
  assert.equal(body.intent, null);
  assert.match(body.not_verified[0], /only 1 price source/);
  const hist = await (await u.call('GET', '/v1/pay/history')).json();
  assert.equal(hist.payments.length, 0);

  const fee = world({ feeBps: 400n });
  await fee.start();
  assert.equal((await fee.call('POST', '/v1/pay/xchain/quote', quoteBody)).status, 422);
});

// ---- audit fixes
test('fix 1: exact input with a minAmountOut far below the slippage is refused', () => {
  const v = judge({ mode: 'exact_in', amount: '10', from: 'USDC', dest: tok('USDC', 'base'), tweak: (q) => { q.quote.minAmountOut = '1'; } });
  assert.equal(v.verified, false);
  assert.match((v as { refused: string }).refused, /minimum output/);
  // The fee is judged on the worst case: 10 in, minimum 9.8901 out (10 bps fee, 100 bps slippage) is 110 bps.
  const ok = judge({ mode: 'exact_in', amount: '10', from: 'USDC', dest: tok('USDC', 'base') });
  assert.ok(ok.ok);
  assert.equal(ok.numbers.fee.bps, '110');
});

test('fix 2: slippage, deadline and deposit mode must echo; slippage above the limit is refused', () => {
  const base = tok('USDC', 'base');
  const r = (tweak: (q: OneClickQuote) => void) => judge({ mode: 'exact_in', amount: '10', from: 'USDC', dest: base, tweak }) as { refused: string };
  assert.match(r((q) => { q.quoteRequest.slippageTolerance = 5000; q.quote.minAmountOut = '4995000'; }).refused, /\(slippageTolerance\)/);
  assert.match(r((q) => { q.quoteRequest.deadline = new Date(Date.now() + 9e6).toISOString(); }).refused, /\(deadline\)/);
  assert.match(r((q) => { q.quoteRequest.depositMode = 'MEMO'; }).refused, /\(depositMode\)/);
  const origin = TOKENS.find((t) => t.assetId === ORIGINS.USDC.assetId)!;
  const sent = quoteRequest({ mode: 'exact_in', units: 10_000_000n, origin, dest: base, recipient: EVM, refundTo: 'cd'.repeat(32), deadline: new Date(Date.now() + 1_800_000), slippageBps: 500, dry: false });
  const v = checkQuote({ mode: 'exact_in', typed: 10_000_000n, origin, dest: base, chainDecimals: { origin: 6, dest: 6 }, sent, q: fakeQuote(sent), prices: { origin: twoSources(origin), dest: twoSources(base) }, limits: defaultLimits({}), now: Date.now(), minDeadlineMs: 0 });
  assert.match((v as { refused: string }).refused, /slippage 500 is above the 100 bps limit/);
});

test('fix 4: a mixed-case EVM address must pass EIP-55', () => {
  assert.ok(checkAddress('base', '0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed').ok);
  assert.ok(checkAddress('base', '0x5aaeb6053f3e94c9b9a09f33669435e7ef1beaed').ok, 'all lower case has no checksum');
  assert.ok(checkAddress('base', '0x5AAEB6053F3E94C9B9A09F33669435E7EF1BEAED').ok, 'all upper case has no checksum');
  const bad = checkAddress('base', '0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAeD');
  assert.equal(bad.ok, false);
  assert.match((bad as { reason: string }).reason, /checksum/);
  const p = parseXchain('send 5 USDC to 0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAeD on base');
  assert.equal(p.valid, false);
  assert.equal(Buffer.from(keccak256(new Uint8Array())).toString('hex'), 'c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470');
});

test('fix 5: a price needs a source independent of 1Click', () => {
  assert.match((agreedPrice([{ source: '1click', price: '1' }, { source: '1click-again', price: '1' }], 200n) as { reason: string }).reason, /independent of 1Click/);
  assert.equal(agreedPrice([{ source: '1click', price: '1' }], 200n).ok, false);
  assert.ok(agreedPrice([{ source: 'relay', price: '1' }, { source: '1click', price: '1' }], 200n).ok);
});

test('pins: prices use Pip\'s own (chain, contract) record; a row that disagrees is refused; unpinned is not verified', async () => {
  const base = tok('USDC', 'base');
  const p = checkPin(base);
  assert.ok(p.ok);
  assert.equal(p.pin.coingeckoId, 'usd-coin');
  assert.deepEqual(p.pin.relay, { chainId: 8453, address: '0x833589fcd6edb6e08f4c7c32d4f71b54bda02913' });
  assert.equal((checkPin(tok('USDC', 'bsc')) as { pin: { decimals: number } }).pin.decimals, 18);
  assert.match((checkPin({ ...base, coingeckoId: 'scam-coin' }) as { refused: string }).refused, /CoinGecko id \(scam-coin\) differs/);
  assert.match((checkPin({ ...base, decimals: 18 }) as { refused: string }).refused, /decimals \(18\) differs/);
  assert.match((checkPin({ ...base, symbol: 'USDT' }) as { refused: string }).refused, /symbol/);
  const unpinned = checkPin({ ...base, contractAddress: '0x1111111111111111111111111111111111111111' });
  assert.equal(unpinned.ok, false);
  assert.equal((unpinned as { refused: unknown }).refused, null);

  // Through the route: a lying row is refused before any quote; an unpinned asset makes no intent.
  const lying = world({ tokens: TOKENS.map((t) => (t === base ? { ...t, coingeckoId: 'scam-coin' } : t)) });
  await lying.start();
  const r = await lying.call('POST', '/v1/pay/xchain/quote', quoteBody);
  assert.equal(r.status, 422);
  assert.equal(lying.quotes.length, 0);
  const odd = world({ tokens: TOKENS.map((t) => (t === base ? { ...t, contractAddress: '0x1111111111111111111111111111111111111111' } : t)) });
  await odd.start();
  const u = await (await odd.call('POST', '/v1/pay/xchain/quote', quoteBody)).json();
  assert.equal(u.verified, false);
  assert.equal(u.intent, null);
  assert.match(u.not_verified[0], /not on Pip's pinned list/);
});

// ---- top tokens: pins, decimal classes, address validators, parser
const B32 = 'qpzry9x8gf2tvdw0s3jn54khce6mua7l';
function b32polymod(v: number[]) {
  const G = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3];
  let c = 1;
  for (const x of v) { const t = c >>> 25; c = ((c & 0x1ffffff) << 5) ^ x; for (let i = 0; i < 5; i++) if ((t >>> i) & 1) c ^= G[i]; }
  return c >>> 0;
}
/** A test-only bech32/bech32m encoder, so validators are checked against addresses built from known bytes. */
function bech32Encode(hrp: string, data: number[], m: boolean) {
  const he = [...[...hrp].map((c) => c.charCodeAt(0) >> 5), 0, ...[...hrp].map((c) => c.charCodeAt(0) & 31)];
  const pm = b32polymod([...he, ...data, 0, 0, 0, 0, 0, 0]) ^ (m ? 0x2bc830a3 : 1);
  const chk = [0, 1, 2, 3, 4, 5].map((i) => (pm >>> (5 * (5 - i))) & 31);
  return `${hrp}1${[...data, ...chk].map((d) => B32[d]).join('')}`;
}
const segwit = (hrp: string, v: number, prog: number[]) => bech32Encode(hrp, [v, ...convertBits(prog, 8, 5, true)!], v > 0);
const b58check = (bytes: number[]) => baseEncode(Buffer.concat([Buffer.from(bytes), createHash('sha256').update(createHash('sha256').update(Buffer.from(bytes)).digest()).digest().subarray(0, 4)]));
const h20 = Array.from({ length: 20 }, (_, i) => i + 1);

test('top tokens: pins cover each decimal class, with a CoinGecko id from CoinGecko itself', () => {
  const p = (k: string) => PINS[k];
  const classes: [string, number][] = [
    ['eth:0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48', 6], ['bsc:0x8ac76a51cc950d9822d68b83fe1ad97b32cd580d', 18], ['bsc:0x55d398326f99059ff775485246999027b3197955', 18],
    ['btc:native', 8], ['doge:native', 8], ['ltc:native', 8], ['bch:native', 8], ['eth:0x2260fac5e5542a773aa44fbcfedf7c193bc2c599', 8],
    ['sol:native', 9], ['sui:native', 9], ['xrp:native', 6], ['cardano:native', 6], ['tron:native', 6],
    ['eth:native', 18], ['bsc:native', 18], ['avax:native', 18], ['eth:0x95ad61b0a150d79219dcf64e1e6cc01f0b64c4ce', 18], ['near:wrap.near', 24],
  ];
  for (const [k, d] of classes) {
    assert.equal(p(k)?.decimals, d, k);
    assert.ok(p(k).coingeckoId && !p(k).unverified, `${k} verified`);
    assert.equal(toBase(fromBase(1n, d), d), 1n, `smallest unit round trip at ${d}`);
  }
  assert.equal(toBase('0.001', 8), 100_000n, '0.001 BTC');
  assert.equal(toBase('50', 6), 50_000_000n, '50 XRP');
  assert.equal(toBase('0.000000001', 8), null, 'BTC has 8 decimals');
  assert.equal(toBase('1000000', 18), 10n ** 24n, '1M SHIB');
  assert.equal(p('bsc:0x8ac76a51cc950d9822d68b83fe1ad97b32cd580d').coingeckoId, 'binance-bridged-usdc-bnb-smart-chain', 'CoinGecko maps the BNB contract to its bridged coin');
  assert.equal(p('bsc:0x8ac76a51cc950d9822d68b83fe1ad97b32cd580d').oneclickCoingeckoId, 'usd-coin');
  assert.ok(checkPin(tok('USDC', 'bsc')).ok, "1Click's own id is accepted when it is the recorded one");
  for (const k of ['ton:EQCxE6mUtQJKFnGfaROTKOt1lZbDiiX1kCixRv7Nw2Id_sDs', 'near:eth.bridge.near', 'sol:3ZLekZYq2qkZiSpnSvabjit34tUkjSwD1JFuW9as9wBG']) assert.ok(p(k).unverified, `${k} is blocked`);
  const ton = checkPin({ assetId: 'x', blockchain: 'ton', symbol: 'USDT', decimals: 6, price: 1, contractAddress: 'EQCxE6mUtQJKFnGfaROTKOt1lZbDiiX1kCixRv7Nw2Id_sDs', coingeckoId: 'tether' });
  assert.equal(ton.ok, false);
  assert.match((ton as { reason: string }).reason, /not verified: decimals not readable/);
});

test('top tokens: address validators per chain', () => {
  const yes = (chain: string, a: string) => assert.ok(checkAddress(chain, a).ok, `${chain} ${a}`);
  const no = (chain: string, a: string) => assert.equal(checkAddress(chain, a).ok, false, `${chain} ${a}`);
  // Bitcoin: legacy P2PKH and P2SH, segwit v0 (20 and 32 bytes, bech32), taproot (bech32m).
  yes('btc', '1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa');
  yes('btc', '3J98t1WpEZ73CNmQviecrnyiWrnqRhWNLy');
  yes('btc', 'bc1qrp33g0q5c5txsp9arysrx4k6zdkfs4nce4xj0gdcccefvpysxf3qccfmv3');
  yes('btc', 'bc1p0xlxvlhemja6c4dqv22uapctqupfhlxm9h8z3k2e72q4k9hcz7vqzk5jj0');
  yes('btc', segwit('bc', 0, h20));
  no('btc', bech32Encode('bc', [0, ...convertBits(h20, 8, 5, true)!], true)); // v0 with the bech32m checksum
  no('btc', '1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNb');
  no('btc', segwit('tb', 0, h20));
  // Litecoin: L/M legacy and ltc1 segwit; a Bitcoin bc1 is not Litecoin.
  yes('ltc', b58check([0x30, ...h20]));
  yes('ltc', b58check([0x32, ...h20]));
  yes('ltc', segwit('ltc', 0, h20));
  no('ltc', segwit('bc', 0, h20));
  // Dogecoin: D (0x1e) and 9/A (0x16).
  yes('doge', b58check([0x1e, ...h20]));
  yes('doge', b58check([0x16, ...h20]));
  no('doge', b58check([0x00, ...h20]));
  // Bitcoin Cash: CashAddr with or without the prefix.
  yes('bch', 'bitcoincash:qpm2qsznhks23z7629mms6s4cwef74vcwvy22gdx6a');
  yes('bch', 'qpm2qsznhks23z7629mms6s4cwef74vcwvy22gdx6a');
  no('bch', 'bitcoincash:qpm2qsznhks23z7629mms6s4cwef74vcwvy22gdx6b');
  no('bch', '1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa');
  // XRP: r-address in Ripple's alphabet with its checksum.
  yes('xrp', 'rHb9CJAWyB4rj91VRWn96DkukG4bwdtyTh');
  yes('xrp', 'rPT1Sjq2YGrBMTttX4GZHjKu9dyfzbpAYe');
  no('xrp', 'rHb9CJAWyB4rj91VRWn96DkukG4bwdtyTi');
  // Cardano Shelley mainnet (CIP-19 vector); a testnet-network address is refused.
  yes('cardano', 'addr1qx2fxv2umyhttkxyxp8x0dlpdt3k6cwng5pxj3jhsydzer3n0d3vllmyqwsx5wktcd8cc3sq835lu7drv2xwl2wywfgse35a3x');
  no('cardano', bech32Encode('addr', convertBits([0x00, ...Array(56).fill(7)], 8, 5, true)!, false));
  no('cardano', 'addr1qx2fxv2umyhttkxyxp8x0dlpdt3k6cwng5pxj3jhsydzer3n0d3vllmyqwsx5wktcd8cc3sq835lu7drv2xwl2wywfgse35a3y');
  // Sui: 0x + 64 hex. TON: friendly form with CRC16, or raw.
  yes('sui', '0x' + 'ab'.repeat(32));
  no('sui', '0x' + 'ab'.repeat(20));
  yes('ton', 'EQCxE6mUtQJKFnGfaROTKOt1lZbDiiX1kCixRv7Nw2Id_sDs');
  yes('ton', '0:' + 'ab'.repeat(32));
  no('ton', 'EQCxE6mUtQJKFnGfaROTKOt1lZbDiiX1kCixRv7Nw2Id_sDt');
  yes('tron', TRON_ADDR);
  yes('sol', SOL_ADDR);
});

test('top tokens: parser reads the new symbols, chains and XRP tags', () => {
  const ok = (text: string, want: Record<string, unknown>) => {
    const r = parseXchain(text);
    assert.ok(r.valid, `${text}: ${!r.valid && r.reason}`);
    for (const [k, v] of Object.entries(want)) assert.equal((r as Record<string, unknown>)[k], v, `${text} ${k}`);
  };
  ok('send 0.001 btc to bc1qrp33g0q5c5txsp9arysrx4k6zdkfs4nce4xj0gdcccefvpysxf3qccfmv3', { token: 'BTC', chain: 'btc', amount: '0.001' });
  ok('send 50 xrp to rHb9CJAWyB4rj91VRWn96DkukG4bwdtyTh tag 123', { token: 'XRP', chain: 'xrp', tag: '123' });
  ok(`pay 10 usdt on tron to ${TRON_ADDR}`, { token: 'USDT', chain: 'tron' });
  ok('send 20 ada to addr1qx2fxv2umyhttkxyxp8x0dlpdt3k6cwng5pxj3jhsydzer3n0d3vllmyqwsx5wktcd8cc3sq835lu7drv2xwl2wywfgse35a3x', { chain: 'cardano', token: 'ADA' });
  ok(`send 3 sui to 0x${'ab'.repeat(32)}`, { chain: 'sui' });
  ok('send 1 doge to ' + b58check([0x1e, ...h20]), { chain: 'doge' });
  ok('send 0.1 bch to bitcoincash:qpm2qsznhks23z7629mms6s4cwef74vcwvy22gdx6a', { chain: 'bch' });
  ok('send 1 ltc to 3J98t1WpEZ73CNmQviecrnyiWrnqRhWNLy on litecoin', { chain: 'ltc' });
  ok(`send 100 shib to ${EVM} on ethereum`, { token: 'SHIB', chain: 'eth' });
  const amb = parseXchain('send 1 ltc to 3J98t1WpEZ73CNmQviecrnyiWrnqRhWNLy');
  assert.match((amb as { reason: string }).reason, /say which chain/, 'a 3… address fits Bitcoin and Litecoin');
  const tag = parseXchain(`send 5 usdt to ${TRON_ADDR} tag 9`);
  assert.match((tag as { reason: string }).reason, /only XRP/);
});

test('top tokens: a tagged XRP payment is blocked at quote', async () => {
  const w = world();
  await w.start();
  const r = await w.call('POST', '/v1/pay/xchain/quote', { amount: '50', token: 'XRP', chain: 'xrp', recipient: 'rHb9CJAWyB4rj91VRWn96DkukG4bwdtyTh', tag: '123' });
  assert.equal(r.status, 400);
  assert.match((await r.json()).error, /tags are not supported/);
  assert.equal(w.quotes.length, 0);
});

// ---- swap, saved addresses, preview, receive (build 0.8)
test('swap parse: 18 cases', () => {
  const ok = (text: string, want: Record<string, unknown>) => {
    const r = parseSwap(text);
    assert.ok(r.valid, `${text}: ${!r.valid && r.reason}`);
    for (const [k, v] of Object.entries(want)) assert.equal((r as Record<string, unknown>)[k], v, `${text} ${k}`);
  };
  const bad = (text: string, reason: RegExp) => {
    const r = parseSwap(text);
    assert.equal(r.valid, false, text);
    assert.match((r as { reason: string }).reason, reason, text);
  };
  ok('swap 1 near to usdc', { amount: '1', from: 'NEAR', token: 'USDC', chain: 'near' });
  ok('swap 5 usdc to usdt', { amount: '5', from: 'USDC', token: 'USDT', chain: 'near' });
  ok('convert 0.5 near into usdc', { amount: '0.5', from: 'NEAR', token: 'USDC', chain: 'near' });
  ok('swap 10 usdc to eth on base', { amount: '10', from: 'USDC', token: 'ETH', chain: 'base' });
  ok('Swap 2 USDT for USDC', { from: 'USDT', token: 'USDC', chain: 'near' });
  ok('exchange 3 near to usdt', { from: 'NEAR', token: 'USDT' });
  ok('can you swap my 1.50 near to usdc pls', { amount: '1.5', from: 'NEAR' });
  ok('swap $5 usdc to usdt', { amount: '5', from: 'USDC', token: 'USDT' });
  ok('swap 2 usdc to near', { token: 'WNEAR', chain: 'near' });
  ok('swap 1 wnear to usdc', { from: 'NEAR', token: 'USDC' });
  ok('swap 20 usdc to sol on solana', { token: 'SOL', chain: 'sol' });
  ok('swap 5 usdt to usdt on tron', { from: 'USDT', token: 'USDT', chain: 'tron' });
  ok('trade 0.000001 usdc to usdt', { amount: '0.000001' });
  bad('swap 1 near to near', /same token/);
  bad('swap 5 usdc to usdc', /same token/);
  bad('swap 1 sol to usdc', /from NEAR, USDC or USDT/);
  bad('swap 1 near to usdc on mars', /does not swap to mars/);
  bad('swap 0 near to usdc', /plain number above zero/);
  bad('swap 1 near to usdc and swap 2 usdc to usdt', /more than one/);
  bad('let us meet at the swap meet', /no swap found/);
  // The keyboard's one parse: payments first, then swaps.
  assert.equal((parseAny('send 5 usdc to 0x8ba1f109551bD432803012645Ac136ddd64DBA72 on base') as { kind: string }).kind, 'xchain');
  assert.equal((parseAny('swap 1 near to usdc') as { kind: string }).kind, 'swap');
});

test('xchain parse: the verb may be left out when the target is an address', () => {
  const read = (text: string) => parseXchain(text) as Record<string, unknown>;
  for (const [text, amount, token, chain] of [
    [`5 usdc to ${EVM} on base`, '5', 'USDC', 'base'],
    [`$5 to ${EVM} on base`, '5', 'USDC', 'base'],
    [`$0.02 USDT to ${TRON_ADDR}`, '0.02', 'USDT', 'tron'],
    [`ok 10 USDT to ${SOL_ADDR} thanks`, '10', 'USDT', 'sol'],
    ['0.05 near to ana.near', '0.05', 'NEAR', 'near'],
  ] as const) {
    const r = read(text);
    assert.equal(r.valid, true, `${text}: ${r.reason}`);
    assert.deepEqual([r.amount, r.token, r.chain], [amount, token, chain], text);
  }
  assert.equal(read(`5 usdc to ${EVM}`).needs, 'chain');
  assert.equal(read(`5 usdc to ${EVM} on base and 6 usdc to ${EVM} on base`).reason, 'more than one payment in the text; send one at a time');
  for (const text of ['swap 1 near to usdc', 'swap 1 near to ana.near', 'I owe 5 dollars to my mom', 'I paid $5 to my mom', 'request 5 usdc on base',
    'ask ana for 5 usdc on base', '1 near to usdc', `15${EVM} on base`, `x5 usdc to ${EVM} on base`, `I sent 5 usdc to ${EVM} on base`]) {
    assert.match(String(read(text).reason), /no payment found/, text);
  }
  const kind = (text: string) => (parseAny(text) as { kind?: string }).kind;
  assert.equal(kind(`5 usdc to ${EVM} on base`), 'xchain');
  assert.equal(kind('swap 1 near to usdc'), 'swap');
  assert.equal(kind('swap $5 to eth'), undefined, 'no swap before, none now');
  assert.equal(kind('request 5 usdc on base'), 'request');
  assert.equal(kind('ask ana for 5 usdc on base'), 'request');
});

test('swap check: exact input spends exactly the typed amount; the minimum received sits on the slippage boundary', () => {
  const dest = tok('USDC', 'near');
  const at = judge({ mode: 'exact_in', amount: '1', from: 'NEAR', dest, tweak: (q) => { q.quote.minAmountOut = ((BigInt(q.quote.amountOut) * 9_900n) / 10_000n).toString(); } });
  assert.ok(at.ok, !at.ok ? String(at.refused ?? at.not_verified) : '');
  assert.equal(at.numbers.amount_in.units, (10n ** 24n).toString(), 'exactly 1 NEAR, 24 decimals');
  assert.equal(at.numbers.mode, 'exact_in');
  const below = judge({ mode: 'exact_in', amount: '1', from: 'NEAR', dest, tweak: (q) => { q.quote.minAmountOut = ((BigInt(q.quote.amountOut) * 9_900n) / 10_000n - 1n).toString(); } });
  assert.equal(below.ok, false);
  assert.match(String(!below.ok && below.refused), /minimum output is more than 100 bps below/);
  const more = judge({ mode: 'exact_in', amount: '1', from: 'NEAR', dest, tweak: (q) => { q.quote.amountIn = (10n ** 24n + 1n).toString(); q.quote.amountInFormatted = fromBase(10n ** 24n + 1n, 24); } });
  assert.match(String(!more.ok && more.refused), /does not spend the exact amount/);
});

test('swap route: NEAR -> USDC to the own account, exact input, no address to confirm; cross-chain needs a saved address', async () => {
  const w = world();
  await w.start();
  const r = await w.call('POST', '/v1/pay/xchain/swap', { amount: '1', from: 'NEAR', token: 'USDC' });
  assert.equal(r.status, 201, await r.clone().text());
  const q = await r.json();
  assert.equal(q.swap, true);
  assert.equal(q.destination.chain, 'near');
  assert.equal(q.destination.recipient, w.keyHex, 'the swap lands in the user\'s own account');
  assert.equal(q.destination.first_time, false);
  assert.equal(q.mode, 'exact_in');
  assert.equal(q.max_amount_in.units, (10n ** 24n).toString());
  assert.equal(q.slippage_bps, 100);
  assert.deepEqual(q.route_path, ['NEAR in your NEAR wallet', 'NEAR Intents solvers', 'USDC on NEAR']);
  assert.equal(w.quotes[0].swapType, 'EXACT_INPUT');
  assert.equal(w.quotes[0].recipient, w.keyHex);
  assert.equal(w.quotes[0].dry, false);
  assert.deepEqual(w.balanceReads[0], { c: null, a: w.keyHex }, 'NEAR is read as the native balance');

  const none = await w.call('POST', '/v1/pay/xchain/swap', { amount: '10', from: 'USDC', token: 'ETH', chain: 'base' });
  assert.equal(none.status, 400);
  const nb = await none.json();
  assert.equal(nb.needs, 'address');
  assert.match(nb.error, /Add your Base address/);
  assert.equal(w.quotes.length, 1, 'no quote without an address');
  assert.equal((await w.call('PUT', '/v1/pay/addresses', { chain: 'base', address: EVM }, true)).status, 200);
  const x = await w.call('POST', '/v1/pay/xchain/swap', { amount: '5', from: 'USDC', token: 'ETH', chain: 'base' });
  assert.equal(x.status, 201, await x.clone().text());
  const xq = await x.json();
  assert.equal(xq.destination.recipient, EVM);
  assert.equal(xq.destination.first_time, false);
  assert.equal(w.quotes[1].recipient, EVM);
  assert.deepEqual(w.balanceReads[1], { c: ORIGINS.USDC.contract, a: w.keyHex });
});

test('swap preview: on mainnet with too little, the checked card says what is missing and makes no intent', async () => {
  const w = world({ balance: 2n * 10n ** 23n });
  await w.start();
  const r = await w.call('POST', '/v1/pay/xchain/swap', { amount: '1', from: 'NEAR', token: 'USDC' });
  assert.equal(r.status, 200);
  const q = await r.json();
  assert.equal(q.preview, true);
  assert.equal(q.preview_reason, 'balance');
  assert.equal(q.verified, true);
  assert.equal(q.intent, null);
  assert.equal(q.action, 'Need 0.8 more NEAR');
  assert.deepEqual(q.need, { units: (8n * 10n ** 23n).toString(), text: '0.8', symbol: 'NEAR' });
  const hist = await (await w.call('GET', '/v1/pay/history')).json();
  assert.equal(hist.payments.length, 0, 'nothing to approve, sign or submit');
  // Testnet swap preview: dry, own implicit account.
  const t = world();
  await t.start('testnet');
  const p = await (await t.call('POST', '/v1/pay/xchain/swap', { amount: '0.5', from: 'NEAR', token: 'USDC' })).json();
  assert.equal(p.preview_reason, 'testnet');
  assert.equal(p.action, 'Switch to Mainnet and add 0.5 NEAR to send');
  assert.equal(t.quotes[0].dry, true);
  assert.equal(t.quotes[0].recipient, t.keyHex);
});

test('my addresses: each chain\'s validator; only the app changes them; NEAR is not a saved chain', async () => {
  const w = world();
  await w.start();
  const put = (chain: string, address: string, app = true) => w.call('PUT', '/v1/pay/addresses', { chain, address }, app);
  assert.equal((await put('base', EVM, false)).status, 403, 'the keyboard cannot change where swaps land');
  assert.equal((await put('base', EVM)).status, 200);
  assert.equal((await put('sol', SOL_ADDR)).status, 200);
  assert.equal((await put('tron', TRON_ADDR)).status, 200);
  const bad = async (chain: string, address: string, reason: RegExp) => {
    const r = await put(chain, address);
    assert.equal(r.status, 400, `${chain} ${address}`);
    assert.match((await r.json()).error, reason);
  };
  await bad('base', '0xD8DA6BF26964AF9D7EED9E10C19B4AE4FF1B9DA3'.slice(0, 41), /not a Base address/);
  await bad('eth', '0xd8dA6BF26964aF9D7eEd9e10C19B4AE4fF1B9DA3', /checksum/);
  await bad('base', '0x' + '0'.repeat(40), /not a Base address/);
  await bad('sol', EVM, /not a Solana address/);
  await bad('tron', 'TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6x', /not a Tron address/);
  await bad('near', 'ana.near', /does not support/);
  await bad('mars', EVM, /does not support/);
  const list = await (await w.call('GET', '/v1/pay/addresses')).json();
  assert.deepEqual(list.addresses.map((a: { chain: string }) => a.chain), ['base', 'sol', 'tron']);
  assert.equal(list.addresses[0].chain_name, 'Base');
  assert.ok(list.chains.some((c: { id: string }) => c.id === 'eth') && !list.chains.some((c: { id: string }) => c.id === 'near'));
  assert.equal((await put('base', '0x8ba1f109551bD432803012645Ac136ddd64DBA72')).status, 200, 'saving again replaces it');
  assert.equal((await w.call('DELETE', '/v1/pay/addresses/sol', undefined, false)).status, 403);
  assert.equal((await w.call('DELETE', '/v1/pay/addresses/sol', undefined, true)).status, 200);
  const after = await (await w.call('GET', '/v1/pay/addresses')).json();
  assert.deepEqual(after.addresses.map((a: { chain: string; address: string }) => [a.chain, a.address]), [['base', '0x8ba1f109551bD432803012645Ac136ddd64DBA72'], ['tron', TRON_ADDR]]);
});

test('request parse: requests and top-ups, with the chain asked for when missing', () => {
  const r = (t: string) => parseRequest(t) as Record<string, unknown>;
  assert.deepEqual(r('request 5 usdc on base'), { valid: true, kind: 'request', amount: '5', token: 'USDC', chain: 'base' });
  assert.deepEqual(r('ask ana for 5 usdc on base'), { valid: true, kind: 'request', amount: '5', token: 'USDC', chain: 'base' });
  assert.equal(r('request 5 usdc from base').chain, 'base');
  assert.equal(r('charge raj 12 usdt on tron').chain, 'tron');
  assert.deepEqual(r('request 5 usdc'), { valid: false, kind: 'request', reason: 'Which chain will they pay from?', needs: 'chain', amount: '5', token: 'USDC' });
  assert.equal(r('request 5 usdc from ana').needs, 'chain', 'a name after "from" is the payer');
  assert.match(String(r('request 5 eth on base').reason), /USDC or USDT/);
  assert.match(String(r('request 5 usdc on near').reason), /share your Pip account/);
  assert.deepEqual(r('top up my pip with 20 usdc from base'), { valid: true, kind: 'topup', amount: '20', token: 'USDC', chain: 'base' });
  assert.equal(r('topup my wallet with 5 usdt on tron').chain, 'tron');
  assert.deepEqual(r('top up my pip from base'), { valid: false, kind: 'topup', reason: 'say how much, like "top up my pip with 20 usdc from base"', needs: 'amount', chain: 'base' });
  assert.equal((parseAny('request 5 usdc on base') as { kind: string }).kind, 'request');
  assert.equal(requestStatus(null, 1000, 999), 'waiting_for_payment');
  assert.equal(requestStatus('PENDING_DEPOSIT', 1000, 1001), 'expired');
  assert.equal(requestStatus('SUCCESS', 1000, 5000), 'received');
  assert.equal(requestStatus('REFUNDED', 1000, 5000), 'refunded');
});

test('request route: a checked deposit address on Base that delivers to the own NEAR account; refunds to the own Intents balance; tracked to "received"', async () => {
  const w = world();
  await w.start();
  const r = await w.call('POST', '/v1/pay/xchain/request', { amount: '5', token: 'USDC', chain: 'base' });
  assert.equal(r.status, 201, await r.clone().text());
  const q = await r.json();
  assert.equal(q.verified, true);
  assert.equal(q.kind, 'request');
  assert.equal(q.deposit_address, EVM_DEPOSIT);
  assert.equal(q.recipient, w.keyHex);
  assert.equal(q.refund_type, 'INTENTS');
  assert.match(q.refund_note, /not to the payer/);
  assert.equal(q.numbers.amount_in.text, '5');
  assert.equal(q.origin.chain_name, 'Base');
  assert.deepEqual(q.route_path, ['USDC on Base', 'NEAR Intents solvers', 'USDC in your Pip wallet']);
  assert.ok(Date.parse(q.valid_until) < Date.parse(q.deadline));
  const sent = w.quotes[0];
  assert.equal(sent.swapType, 'EXACT_INPUT');
  assert.equal(sent.originAsset, tok('USDC', 'base').assetId);
  assert.equal(sent.destinationAsset, ORIGINS.USDC.assetId);
  assert.equal(sent.recipient, w.keyHex);
  assert.equal(sent.refundTo, w.keyHex);
  assert.equal(sent.refundType, 'INTENTS');
  assert.equal(sent.dry, false);
  assert.equal(w.fake.sent.length, 0, 'Pip broadcasts nothing');
  assert.equal(w.balanceReads.length, 0);
  assert.equal((await (await w.call('GET', '/v1/pay/history')).json()).payments.length, 0, 'no phone intent');

  w.setOcStatus({ status: 'PENDING_DEPOSIT' });
  const s1 = await (await w.call('GET', `/v1/pay/xchain/requests/${q.request.id}`)).json();
  assert.equal(s1.status, 'waiting_for_payment');
  w.setOcStatus({ status: 'SUCCESS', swapDetails: { amountOut: '4994000' } });
  w.tick(6_000);
  const s2 = await (await w.call('GET', `/v1/pay/xchain/requests/${q.request.id}`)).json();
  assert.equal(s2.status, 'received');
  assert.deepEqual(s2.received, { text: '4.994', symbol: 'USDC' });

  // Top-up is the same flow; a deposit address that is not on the payer's chain is refused.
  const top = await (await w.call('POST', '/v1/pay/xchain/request', { amount: '20', token: 'USDC', chain: 'base', kind: 'topup' })).json();
  assert.equal(top.kind, 'topup');
  assert.equal(top.deposit_address, EVM_DEPOSIT);
  const sol = await w.call('POST', '/v1/pay/xchain/request', { amount: '5', token: 'USDC', chain: 'sol' });
  assert.equal(sol.status, 422, 'the fake deposit is an EVM address, not a Solana one');
  const sb = await sol.json();
  assert.match(sb.error, /deposit address is not a sol address/);
  assert.equal(sb.deposit_address, undefined);
});

test('request preview: on testnet a dry quote, no deposit address, no request row', async () => {
  const t = world();
  await t.start('testnet');
  const r = await t.call('POST', '/v1/pay/xchain/request', { amount: '5', token: 'USDC', chain: 'base' });
  assert.equal(r.status, 200);
  const q = await r.json();
  assert.equal(q.preview, true);
  assert.equal(q.verified, true);
  assert.equal(q.request, null);
  assert.equal(q.deposit_address, undefined);
  assert.equal(q.action, 'Switch to Mainnet to get a real deposit address');
  assert.equal(t.quotes[0].dry, true);
  assert.equal((await t.call('POST', '/v1/pay/xchain/request', { amount: '5', token: 'USDC', chain: 'near' })).status, 400);
});
