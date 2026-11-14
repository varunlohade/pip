import type { Context, Hono } from 'hono';
import { randomBytes } from 'node:crypto';
import { z } from 'zod';
import type { Db } from '../../db.ts';
import { HttpError, type Env } from '../../http.ts';
import { log } from '../../log.ts';
import { payConfig, type PayConfig, type Token } from '../config.ts';
import { mainnetConfig, openNetworkStore, type MainnetConfig } from '../network.ts';
import { toUnits } from '../parse.ts';
import { approverOk } from '../routes.ts';
import { openPayStore } from '../store.ts';
import { openPhoneStore, type PhoneIntent } from '../phone/store.ts';
import type { XchainHooks } from '../phone/routes.ts';
import { CHAINS, ORIGINS, checkAddress, findOrigin, findToken, type Origin, type TokenRow } from './assets.ts';
import { checkPin, type VerifiedPin as Pin } from './pins.ts';
import { checkQuote, defaultLimits, quoteRequest, typedUnits, type Limits, type Mode, type Numbers } from './check.ts';
import { createChainDecimals, type ChainDecimals } from './decimals.ts';
import { chainName, parseAny } from './parse.ts';
import { coingeckoSource, createOneClick, relaySource, type OneClick, type OneClickStatus, type PriceSource } from './sources.ts';
import { openOwnAddressStore, openRequestStore, openXchainStore, type RequestRow, type XchainRow } from './store.ts';
import { fromBase } from './units.ts';
import { buildDeposit } from './tx.ts';
import { createNearViews, type NearViews } from './views.ts';

export type XchainDeps = { oneclick?: OneClick; prices?: PriceSource[]; chainDecimals?: ChainDecimals; views?: NearViews; limits?: Limits; mainnet?: MainnetConfig };

const QUOTE_MAX_AGE_MS = 60_000;
// An xchain intent can be signed for 2 minutes after its quote (or re-quote).
const SIGN_WINDOW_MS = 2 * 60_000;
const DEADLINE_MS = 30 * 60_000;
// The deposit must land well before 1Click's deadline: the intent expires at least this long before it.
const DEADLINE_MARGIN_MS = 15 * 60_000;
const STATUS_EVERY_MS = 5_000;
// A receive request's deposit address stays open this long; it is shown as valid until the margin before it.
const REQUEST_DEADLINE_MS = 60 * 60_000;
const DAY = 86_400_000;

const Quote = z.object({
  amount: z.string().max(40), token: z.string().max(12), chain: z.string().max(16), recipient: z.string().max(100),
  from: z.enum(['NEAR', 'USDC', 'USDT']).optional(), tag: z.string().regex(/^\d{1,10}$/).optional(), mode: z.enum(['exact_out', 'exact_in']).optional(), dry: z.boolean().optional(),
}).strict();
const Swap = z.object({
  amount: z.string().max(40), from: z.enum(['NEAR', 'USDC', 'USDT']), token: z.string().max(12), chain: z.string().max(16).optional(),
}).strict();
const Request = z.object({
  amount: z.string().max(40), token: z.enum(['USDC', 'USDT']), chain: z.string().max(16), kind: z.enum(['request', 'topup']).optional(),
}).strict();
const OwnAddress = z.object({ chain: z.string().max(16), address: z.string().trim().min(1).max(100) }).strict();
const ParseBody = z.object({ text: z.string().trim().min(1).max(500) }).strict();
const IntentId = z.string().regex(/^[0-9a-f]{32}$/);

/** The 1Click token list itself as a price source (the third, least independent one). */
const listSource: PriceSource = { name: '1click', price: async (t) => t.price ?? null };

/** Where a payment stands, from the phone intent and 1Click's status. */
export function mapStatus(intent: PhoneIntent['status'], oc?: OneClickStatus['status'] | null): string {
  if (intent === 'pending' || intent === 'built') return 'awaiting_signature';
  if (intent === 'rejected' || intent === 'expired' || intent === 'sending') return intent;
  if (intent === 'failed') return 'not_sent';
  switch (oc) {
    case 'PENDING_DEPOSIT': return 'waiting_for_deposit';
    case 'KNOWN_DEPOSIT_TX': return 'deposit_seen';
    case 'INCOMPLETE_DEPOSIT': return 'incomplete_deposit';
    case 'PROCESSING': return 'swapping';
    case 'SUCCESS': return 'delivered';
    case 'REFUNDED': return 'refunded';
    case 'FAILED': return 'failed';
    default: return 'checking';
  }
}

/** Where a receive request stands, from 1Click's status of its deposit address. */
export function requestStatus(oc: OneClickStatus['status'] | null | undefined, deadline: number, now: number): string {
  switch (oc) {
    case 'KNOWN_DEPOSIT_TX': return 'deposit_seen';
    case 'INCOMPLETE_DEPOSIT': return 'incomplete_deposit';
    case 'PROCESSING': return 'arriving';
    case 'SUCCESS': return 'received';
    case 'REFUNDED': return 'refunded';
    case 'FAILED': return 'failed';
    default: return now > deadline ? 'expired' : 'waiting_for_payment';
  }
}

/** The card's route, step by step: "NEAR in your wallet" -> solvers -> "USDC on Base". */
export const routePath = (from: string, to: string) => [from, 'NEAR Intents solvers', to];
const shown = (symbol: string) => (symbol.toUpperCase() === 'WNEAR' ? 'NEAR' : symbol);

/** The default origin: the same stablecoin on NEAR when the destination is USDC or USDT elsewhere, USDC for USDT on NEAR, else NEAR. */
export const defaultOrigin = (token: string, chain: string): Origin =>
  (chain === 'near' && token === 'USDT' ? 'USDC' : token === 'USDC' || token === 'USDT' ? token : 'NEAR');

/**
 * Pay any token on any chain from the user's NEAR account through NEAR Intents (1Click). Mainnet only.
 * A checked quote becomes a normal phone intent whose tx deposits the exact max input into 1Click's deposit account.
 */
export function xchainRoutes(app: Hono<Env>, base: { db: Db; now: () => number }, cfg: PayConfig = payConfig, deps: XchainDeps = {}): { hooks: XchainHooks } {
  const { db, now } = base;
  const main = deps.mainnet ?? mainnetConfig;
  const oneclick = deps.oneclick ?? createOneClick();
  const prices = deps.prices ?? [coingeckoSource(), relaySource(), listSource];
  const chainDecimals = deps.chainDecimals ?? createChainDecimals();
  const views = deps.views ?? createNearViews(main.rpcUrl);
  const limits = deps.limits ?? defaultLimits();
  const phone = openPhoneStore(db, now);
  const networks = openNetworkStore(db, now);
  const store = openXchainStore(db, now);
  const own = openOwnAddressStore(db, now);
  const requests = openRequestStore(db, now);
  const pay = openPayStore(db, now);
  const isApp = (c: Context<Env>) => {
    const a = pay.approver(c.get('userId'));
    return !!a && approverOk(c, a.key_hash);
  };

  const json = async <T extends z.ZodTypeAny>(c: Context<Env>, schema: T): Promise<z.infer<T>> => schema.parse(await c.req.json().catch(() => {
    throw new HttpError(400, 'body must be JSON');
  }));
  const priceAll = (t: TokenRow, pin: Pin) => Promise.all(prices.map(async (s) => ({ source: s.name, price: await s.price(t, pin).catch(() => null) })));

  const describe = (r: XchainRow) => {
    const n = JSON.parse(r.numbers_json) as Numbers;
    const swap = r.kind === 'swap';
    return {
      kind: 'xchain', swap, route: 'NEAR Intents (1Click)', verified: true, mode: r.mode, slippage_bps: limits.slippageBps,
      route_path: routePath(`${shown(n.amount_in.symbol)} in your NEAR wallet`, `${n.amount_out.symbol} on ${chainName(r.dest_chain)}`),
      // A swap goes to the user's own account or saved address: there is no stranger's address to confirm.
      destination: { chain: r.dest_chain, chain_name: chainName(r.dest_chain), recipient: r.dest_recipient, asset: r.dest_asset, first_time: swap ? false : !store.paidBefore(r) },
      amount_out: n.amount_out, min_amount_out: n.min_amount_out, max_amount_in: n.max_amount_in, min_amount_in: n.min_amount_in,
      fee: n.fee, rate: n.rate, usd: n.usd, eta_seconds: n.eta_seconds,
      deposit_address: r.deposit_address, refund_to: r.refund_to,
      quote_at: new Date(r.quote_at).toISOString(), quote_expires_at: new Date(r.quote_at + QUOTE_MAX_AGE_MS).toISOString(), deadline: new Date(r.deadline).toISOString(),
    };
  };

  /** A swap names no recipient: it goes to the user's own NEAR account, or their saved address on another chain. */
  type Input = { amount: string; token: string; chain: string; recipient?: string; from?: Origin; tag?: string; mode?: Mode; dry?: boolean; swap?: boolean };
  /** Why a quote is only a preview: the user is on testnet, the server has mainnet off, or the wallet holds too little. */
  type Preview = 'testnet' | 'mainnet_off' | 'balance';
  type Fail = { ok: false; status: 200 | 400 | 403 | 409 | 422 | 502; body: Record<string, unknown> };
  const fail = (status: Fail['status'], error: string, extra: Record<string, unknown> = {}): Fail => ({ ok: false, status, body: { error, ...extra } });
  const answer = (body: Record<string, unknown>): Fail => ({ ok: false, status: 200, body });

  /**
   * Validates, quotes and checks one payment, then applies the caps. Shared by /quote, /swap and the re-quote before signing.
   * A preview runs the same checks on a real dry quote and makes no intent; there is nothing to sign.
   */
  async function runQuote(userId: string, body: Input, preview: Preview | null = null) {
    const main_ = phone.account(userId, 'mainnet');
    // A preview on testnet uses the phone's implicit account id: the same key owns it on mainnet.
    const account = main_?.status === 'ready' ? main_ : preview ? phone.account(userId, 'testnet') ?? main_ : main_;
    if (!account || (!preview && account.status !== 'ready')) return fail(409, preview ? 'set up Pip Pay in the Pip app first' : 'register your key in the Pip app first');
    const chain = body.chain.toLowerCase();
    if (!CHAINS[chain]) return fail(400, `Pip does not pay to ${body.chain} yet`);
    let recipient = body.recipient;
    if (recipient === undefined) {
      if (!body.swap) return fail(400, 'say who to pay');
      recipient = chain === 'near' ? account.account_id : own.get(userId, chain);
      if (!recipient) return fail(400, `Add your ${chainName(chain)} address in Pip Pay > My addresses first`, { needs: 'address', chain });
    }
    const addr = checkAddress(chain, recipient);
    if (!addr.ok) return fail(400, addr.reason);
    // How 1Click carries an XRP destination tag is not verified yet; a tagged payment is blocked rather than sent without its tag.
    if (body.tag !== undefined) return fail(400, 'XRP destination tags are not supported yet');
    const token = body.token.toUpperCase();
    const from = body.from ?? defaultOrigin(token, chain);
    if (chain === 'near' && token === from && (token === 'NEAR' || token === 'USDC')) return fail(400, 'same token on NEAR: use a plain payment (/v1/pay/intents)');
    // A named NEAR account must exist, as for plain sends. An implicit id may not exist yet.
    if (chain === 'near' && !/^[0-9a-f]{64}$/.test(recipient)) {
      const exists = await views.accountExists(recipient).catch((e: Error) => {
        log('pay_rpc_failed', { network: 'mainnet', err: e.message });
        return undefined;
      });
      if (exists === undefined) return fail(502, 'could not reach NEAR mainnet; try again');
      if (!exists) return fail(400, `${recipient} does not exist on mainnet`);
    }
    // "swap 1 near" spends exactly 1 NEAR; a payment delivers exactly what was typed.
    const mode: Mode = body.mode ?? (body.swap ? 'exact_in' : 'exact_out');

    let list: TokenRow[];
    try {
      list = await oneclick.tokens();
    } catch (e) {
      log('xchain_oneclick_failed', { step: 'tokens', err: (e as Error).message });
      return fail(502, 'could not reach NEAR Intents; try again');
    }
    const origin = findOrigin(list, from);
    if (!origin) return fail(400, `${from} on NEAR is not supported by NEAR Intents`);
    const found = findToken(list, token, chain);
    if (!found.ok) return fail(400, found.reason);
    const dest = found.token;
    if (dest.assetId === origin.assetId) return fail(400, 'same token on NEAR: use a plain payment');
    // Each asset must match Pip's own pin; prices are looked up with the pin, not 1Click's row.
    const extra = {
      swap: !!body.swap, slippage_bps: limits.slippageBps, route_path: routePath(`${shown(origin.symbol)} in your NEAR wallet`, `${dest.symbol} on ${chainName(chain)}`),
      ...(preview ? { preview: true, preview_reason: preview } : {}),
    };
    const pins: Pin[] = [];
    for (const t of [origin, dest]) {
      const p = checkPin(t);
      if (!p.ok) return p.refused ? fail(422, p.refused, { verified: false, ...extra }) : answer({ verified: false, not_verified: [p.reason], numbers: null, intent: null, ...extra });
      pins.push(p.pin);
    }
    const typed = typedUnits(body.amount, mode, origin, dest);
    if (!typed.ok) return fail(400, typed.reason);

    const at = now();
    const sent = quoteRequest({ mode, units: typed.units, origin, dest, recipient, refundTo: account.account_id, deadline: new Date(at + DEADLINE_MS), slippageBps: limits.slippageBps, dry: preview !== null || (body.dry ?? false) });
    const [liveIn, liveOut, pIn, pOut, q] = await Promise.all([
      chainDecimals(origin).catch(() => null), chainDecimals(dest).catch(() => null), priceAll(origin, pins[0]), priceAll(dest, pins[1]),
      oneclick.quote(sent).catch((e: Error) => e),
    ]);
    if (q instanceof Error) {
      log('xchain_oneclick_failed', { step: 'quote', err: q.message });
      return fail(502, `NEAR Intents could not quote this: ${q.message}`);
    }
    const v = checkQuote({ mode, typed: typed.units, origin, dest, chainDecimals: { origin: liveIn, dest: liveOut }, sent, q, prices: { origin: pIn, dest: pOut }, limits, now: at, minDeadlineMs: DEADLINE_MARGIN_MS + SIGN_WINDOW_MS });
    log('xchain_quote', {
      user_id: userId, mode, chain, swap: !!body.swap, preview, typed_text: body.amount, typed_units: typed.units.toString(), origin: origin.assetId, dest: dest.assetId,
      amount_in: v.numbers?.amount_in.text ?? null, amount_in_units: q.quote?.amountIn ?? null, amount_out: v.numbers?.amount_out.text ?? null, amount_out_units: q.quote?.amountOut ?? null,
      fee_usd: v.numbers?.fee.usd ?? null, verified: v.verified, refused: v.ok ? null : v.refused, correlation_id: q.correlationId,
    });
    if (!v.ok) {
      if (v.refused) return fail(422, v.refused, { verified: false, numbers: v.numbers, ...extra });
      return answer({ verified: false, not_verified: v.not_verified, numbers: v.numbers, intent: null, ...extra });
    }
    const destination = { chain, chain_name: chainName(chain), recipient, first_time: body.swap ? false : undefined };
    const card = { numbers: v.numbers, destination, route: 'NEAR Intents (1Click)', refund_to: account.account_id, intent: null, ...extra };
    const sym = shown(v.numbers.amount_in.symbol);
    if (preview) {
      const action = preview === 'testnet' ? `Switch to Mainnet and add ${v.numbers.amount_in.text} ${sym} to send` : 'Mainnet payments are off on this server';
      return answer({ verified: true, dry: true, ...card, action, need: null });
    }
    if (body.dry) return answer({ verified: true, dry: true, ...card });

    // Caps on the max input, in the origin token, with the same per-network limits as plain sends.
    const tok = from as Token;
    const units = BigInt(q.quote.amountIn);
    const amount = v.numbers.amount_in.text;
    if (toUnits(amount, tok) !== units) return fail(422, 'decimals for the origin token disagree with the wallet');
    const cap = main.caps[tok];
    if (units > toUnits(cap.perTx, tok)) return fail(403, `over the ${cap.perTx} ${tok} limit per payment`, { verified: true, numbers: v.numbers });
    if (phone.spentSince(userId, 'mainnet', tok, at - DAY) + units > toUnits(cap.daily, tok)) return fail(403, `over the ${cap.daily} ${tok} daily limit`, { verified: true, numbers: v.numbers });
    // Too little in the wallet: the same checked numbers as a preview, with what is missing. Nothing to sign.
    const { contract, wrap } = ORIGINS[from];
    const held = await views.balance(wrap ? null : contract, account.account_id).catch((e: Error) => {
      log('pay_rpc_failed', { network: 'mainnet', err: e.message });
      return null;
    });
    if (held === null) return fail(502, 'could not reach NEAR mainnet; try again');
    if (held < units) {
      const need = { units: (units - held).toString(), text: fromBase(units - held, origin.decimals), symbol: sym };
      return answer({ verified: true, dry: true, ...card, preview: true, preview_reason: 'balance' satisfies Preview, action: `Need ${need.text} more ${sym}`, need });
    }
    return { ok: true as const, v, q, origin, dest, at, tok, units, amount, account, chain, mode, recipient, deadline: Date.parse(q.quote.deadline!) };
  }

  const hooks: XchainHooks = {
    describe(id) {
      const r = store.get(id);
      return r ? describe(r) : null;
    },
    /** A quote older than 60 s is quoted and checked again before the tx is built; the intent takes the new numbers. */
    async refresh(i) {
      const r = store.get(i.id);
      if (!r || now() - r.quote_at <= QUOTE_MAX_AGE_MS) return { requoted: false };
      const n = JSON.parse(r.numbers_json) as Numbers;
      const from = (Object.keys(ORIGINS) as Origin[]).find((o) => ORIGINS[o].assetId === r.origin_asset)!;
      const res = await runQuote(i.user_id, {
        amount: r.mode === 'exact_out' ? n.amount_out.text : n.amount_in.text, token: n.amount_out.symbol, chain: r.dest_chain, recipient: r.dest_recipient, from, mode: r.mode as Mode,
        swap: r.kind === 'swap',
      });
      if (!res.ok) {
        const why = String(res.body.action ?? res.body.error ?? (res.body.not_verified as string[] | undefined)?.join('; ') ?? 'not verified');
        return { status: res.status === 200 ? 409 : res.status, error: `new quote: ${why}` };
      }
      if (res.dest.assetId !== r.dest_asset) return { status: 409, error: 'new quote: the destination token changed; start again' };
      const moved = db.tx(() => {
        if (!store.requote(i.id, { amount: res.amount, units: res.units.toString(), depositAddress: res.q.quote.depositAddress!, expiresAt: Math.min(res.at + SIGN_WINDOW_MS, res.deadline - DEADLINE_MARGIN_MS), numbersJson: JSON.stringify(res.v.numbers), quoteJson: JSON.stringify(res.q), quoteAt: res.at, deadline: res.deadline })) return false;
        return true;
      });
      return moved ? { requoted: true } : { status: 409, error: 'this payment changed; open it again' };
    },
    async build(i, ctx) {
      const r = store.get(i.id);
      if (!r) return null;
      const origin = (Object.keys(ORIGINS) as Origin[]).find((o) => ORIGINS[o].assetId === r.origin_asset)!;
      const { contract, wrap } = ORIGINS[origin];
      const [signerReg, depositReg] = await Promise.all([wrap ? views.storageRegistered(contract, ctx.signerId) : true, views.storageRegistered(contract, r.deposit_address)]);
      const min = signerReg && depositReg ? 0n : await views.storageMin(contract);
      return buildDeposit({ ...ctx, contract, wrap, depositAddress: r.deposit_address, units: BigInt(i.units), signerStorage: signerReg ? null : min, depositStorage: depositReg ? null : min });
    },
  };

  app.post('/v1/pay/xchain/parse', async (c) => c.json({ ...parseAny((await json(c, ParseBody)).text), source: 'regex' }));

  /** Quote, check and (on mainnet with enough funds) propose. On testnet, with mainnet off, or with too little, a live preview. */
  async function propose(c: Context<Env>, body: Input) {
    const userId = c.get('userId');
    const preview: Preview | null = networks.get(userId) !== 'mainnet' ? 'testnet' : !main.enabled ? 'mainnet_off' : null;
    const res = await runQuote(userId, body, preview);
    if (!res.ok) return c.json(res.body, res.status);
    const { v, q, origin, dest, at, tok, units, amount, account, chain, mode, deadline } = res;
    const id = randomBytes(16).toString('hex');
    db.tx(() => {
      phone.addIntent({
        id, user_id: userId, network: 'mainnet', token: tok, amount, units: units.toString(), recipient: q.quote.depositAddress!,
        new_recipient: 1, created_at: at, expires_at: Math.min(at + SIGN_WINDOW_MS, deadline - DEADLINE_MARGIN_MS),
      });
      store.add({
        intent_id: id, user_id: userId, origin_asset: origin.assetId, dest_asset: dest.assetId, dest_chain: chain, dest_recipient: res.recipient,
        deposit_address: q.quote.depositAddress!, refund_to: account.account_id, mode, numbers_json: JSON.stringify(v.numbers), quote_json: JSON.stringify(q), quote_at: at, deadline,
        kind: body.swap ? 'swap' : 'pay',
      });
    });
    const i = phone.intent(id)!;
    return c.json({
      ...describe(store.get(id)!),
      intent: { id, amount: i.amount, token: i.token, recipient: i.recipient, status: i.status, network: 'mainnet', expires_at: new Date(i.expires_at).toISOString(), deep_link: `pip://approve/${id}` },
    }, 201);
  }

  app.post('/v1/pay/xchain/quote', async (c) => propose(c, await json(c, Quote)));

  /** "swap 1 near to usdc": exact input from the user's NEAR wallet to their own account, or to their saved address on another chain. */
  app.post('/v1/pay/xchain/swap', async (c) => {
    const b = await json(c, Swap);
    return propose(c, { amount: b.amount, from: b.from, token: b.token, chain: b.chain ?? 'near', swap: true });
  });

  // ---- My addresses: the user's own address per chain, checked by that chain's validator. Only the app changes them.
  app.get('/v1/pay/addresses', (c) => c.json({
    addresses: own.list(c.get('userId')).map((a) => ({ ...a, chain_name: chainName(a.chain) })),
    chains: Object.keys(CHAINS).filter((id) => id !== 'near').map((id) => ({ id, name: CHAINS[id].name })),
  }));
  app.put('/v1/pay/addresses', async (c) => {
    if (!isApp(c)) return c.json({ error: 'change your addresses in the Pip app' }, 403);
    const b = await json(c, OwnAddress);
    const chain = b.chain.toLowerCase();
    if (!CHAINS[chain] || chain === 'near') return c.json({ error: `Pip does not support ${b.chain} here` }, 400);
    const ok = checkAddress(chain, b.address);
    if (!ok.ok) return c.json({ error: ok.reason }, 400);
    own.set(c.get('userId'), chain, b.address);
    return c.json({ chain, chain_name: chainName(chain), address: b.address });
  });
  app.delete('/v1/pay/addresses/:chain', (c) => {
    if (!isApp(c)) return c.json({ error: 'change your addresses in the Pip app' }, 403);
    return own.remove(c.get('userId'), c.req.param('chain').toLowerCase()) ? c.json({ ok: true }) : c.json({ error: 'no address for that chain' }, 404);
  });

  // ---- Receive: "request 5 usdc on base" and "top up my pip from base". 1Click gives a deposit address on the payer's chain that
  // delivers to the user's own NEAR account. Pip signs nothing and moves no money; it only quotes, checks and watches.
  const REFUND_NOTE = "If the payment fails or comes in after the deadline, NEAR Intents refunds it to your Pip account's NEAR Intents balance, not to the payer.";
  const describeRequest = (r: RequestRow) => {
    const n = JSON.parse(r.numbers_json) as Numbers;
    return {
      kind: r.kind, verified: true, route: 'NEAR Intents (1Click)', slippage_bps: limits.slippageBps,
      route_path: routePath(`${n.amount_in.symbol} on ${chainName(r.origin_chain)}`, `${n.amount_out.symbol} in your Pip wallet`),
      origin: { chain: r.origin_chain, chain_name: chainName(r.origin_chain) }, numbers: n, deposit_address: r.deposit_address, recipient: r.recipient,
      refund_to: r.refund_to, refund_type: 'INTENTS', refund_note: REFUND_NOTE,
      valid_until: new Date(r.deadline - DEADLINE_MARGIN_MS).toISOString(), deadline: new Date(r.deadline).toISOString(),
    };
  };

  app.post('/v1/pay/xchain/request', async (c) => {
    const userId = c.get('userId');
    const b = await json(c, Request);
    const kind = b.kind ?? 'request';
    const main_ = phone.account(userId, 'mainnet');
    const live = networks.get(userId) === 'mainnet' && main.enabled && main_?.status === 'ready';
    const account = main_?.status === 'ready' ? main_ : phone.account(userId, 'testnet') ?? main_;
    if (!account) return c.json({ error: 'set up Pip Pay in the Pip app first' }, 409);
    const chain = b.chain.toLowerCase();
    if (!CHAINS[chain] || chain === 'near') return c.json({ error: `Pip does not take payments from ${b.chain} yet` }, 400);
    let list: TokenRow[];
    try {
      list = await oneclick.tokens();
    } catch (e) {
      log('xchain_oneclick_failed', { step: 'tokens', err: (e as Error).message });
      return c.json({ error: 'could not reach NEAR Intents; try again' }, 502);
    }
    const found = findToken(list, b.token, chain);
    if (!found.ok) return c.json({ error: found.reason }, 400);
    const origin = found.token, dest = findOrigin(list, b.token);
    if (!dest) return c.json({ error: `${b.token} on NEAR is not supported by NEAR Intents` }, 400);
    const extra = {
      kind, slippage_bps: limits.slippageBps, route_path: routePath(`${origin.symbol} on ${chainName(chain)}`, `${dest.symbol} in your Pip wallet`),
      origin: { chain, chain_name: chainName(chain) }, refund_type: 'INTENTS', refund_note: REFUND_NOTE, ...(live ? {} : { preview: true, preview_reason: networks.get(userId) !== 'mainnet' ? 'testnet' : !main.enabled ? 'mainnet_off' : 'no_account' }),
    };
    const pins: Pin[] = [];
    for (const t of [origin, dest]) {
      const p = checkPin(t);
      if (!p.ok) return p.refused ? c.json({ error: p.refused, verified: false, ...extra }, 422) : c.json({ verified: false, not_verified: [p.reason], numbers: null, request: null, ...extra });
      pins.push(p.pin);
    }
    const typed = typedUnits(b.amount, 'exact_in', origin, dest);
    if (!typed.ok) return c.json({ error: typed.reason }, 400);
    const at = now();
    const sent = quoteRequest({ mode: 'exact_in', units: typed.units, origin, dest, recipient: account.account_id, refundTo: account.account_id, refundType: 'INTENTS', deadline: new Date(at + REQUEST_DEADLINE_MS), slippageBps: limits.slippageBps, dry: !live });
    const [liveIn, liveOut, pIn, pOut, q] = await Promise.all([
      chainDecimals(origin).catch(() => null), chainDecimals(dest).catch(() => null), priceAll(origin, pins[0]), priceAll(dest, pins[1]),
      oneclick.quote(sent).catch((e: Error) => e),
    ]);
    if (q instanceof Error) {
      log('xchain_oneclick_failed', { step: 'request_quote', err: q.message });
      return c.json({ error: `NEAR Intents could not quote this: ${q.message}` }, 502);
    }
    const v = checkQuote({ mode: 'exact_in', typed: typed.units, origin, dest, chainDecimals: { origin: liveIn, dest: liveOut }, sent, q, prices: { origin: pIn, dest: pOut }, limits, now: at, minDeadlineMs: DEADLINE_MARGIN_MS + SIGN_WINDOW_MS, depositChain: chain });
    log('xchain_request', { user_id: userId, kind, chain, live, typed_units: typed.units.toString(), verified: v.verified, refused: v.ok ? null : v.refused, correlation_id: q.correlationId });
    // A quote that failed a check never shows its deposit address.
    if (!v.ok) {
      if (v.refused) return c.json({ error: v.refused, verified: false, numbers: v.numbers, ...extra }, 422);
      return c.json({ verified: false, not_verified: v.not_verified, numbers: v.numbers, request: null, ...extra });
    }
    if (!live) {
      const action = extra.preview_reason === 'testnet' ? 'Switch to Mainnet to get a real deposit address' : extra.preview_reason === 'mainnet_off' ? 'Mainnet payments are off on this server' : 'Set up your mainnet account in Pip Pay first';
      return c.json({ verified: true, dry: true, numbers: v.numbers, refund_to: account.account_id, request: null, action, ...extra });
    }
    const id = randomBytes(16).toString('hex');
    requests.add({
      id, user_id: userId, kind, origin_asset: origin.assetId, origin_chain: chain, dest_asset: dest.assetId, recipient: account.account_id, deposit_address: q.quote.depositAddress!,
      refund_to: account.account_id, numbers_json: JSON.stringify(v.numbers), quote_json: JSON.stringify(q), quote_at: at, deadline: Date.parse(q.quote.deadline!),
    });
    return c.json({ ...describeRequest(requests.get(id)!), request: { id, status: 'waiting_for_payment' } }, 201);
  });

  app.get('/v1/pay/xchain/requests/:id', async (c) => {
    const id = IntentId.safeParse(c.req.param('id'));
    const r = id.success ? requests.get(id.data) : undefined;
    if (!r || r.user_id !== c.get('userId')) return c.json({ error: 'no such request' }, 404);
    const done = r.status === 'SUCCESS' || r.status === 'REFUNDED' || r.status === 'FAILED';
    if (!done && (!r.status_at || now() - r.status_at >= STATUS_EVERY_MS)) {
      try {
        const s = await oneclick.status(r.deposit_address);
        requests.setStatus(r.id, s.status, JSON.stringify(s));
      } catch (e) {
        log('xchain_oneclick_failed', { step: 'request_status', err: (e as Error).message });
      }
    }
    const fresh = requests.get(r.id)!;
    const s = fresh.status_json ? (JSON.parse(fresh.status_json) as OneClickStatus) : null;
    const n = JSON.parse(fresh.numbers_json) as Numbers;
    const status = requestStatus(s?.status, fresh.deadline, now());
    const got = s?.swapDetails?.amountOut && /^\d+$/.test(s.swapDetails.amountOut) ? fromBase(BigInt(s.swapDetails.amountOut), n.amount_out.decimals) : null;
    return c.json({
      ...describeRequest(fresh), request: { id: fresh.id, status }, status, oneclick_status: s?.status ?? null,
      received: status === 'received' ? { text: got ?? n.min_amount_out.text, symbol: n.amount_out.symbol } : null,
      refund_reason: s?.swapDetails?.refundReason ?? null,
    });
  });

  app.get('/v1/pay/xchain/:id', async (c) => {
    const id = IntentId.safeParse(c.req.param('id'));
    const r = id.success ? store.get(id.data) : undefined;
    const i = r && phone.intent(r.intent_id);
    if (!r || !i || r.user_id !== c.get('userId')) return c.json({ error: 'no such payment' }, 404);
    const sentish = i.status === 'sent' || i.status === 'outcome_unknown';
    if (sentish && i.tx_hash && store.claimNotice(r.intent_id)) {
      await oneclick.submitDeposit({ txHash: i.tx_hash, depositAddress: r.deposit_address, nearSenderAccount: r.refund_to })
        .catch((e: Error) => log('xchain_oneclick_failed', { step: 'deposit_submit', err: e.message }));
    }
    if (sentish && (!r.status_at || now() - r.status_at >= STATUS_EVERY_MS)) {
      try {
        const s = await oneclick.status(r.deposit_address);
        store.setStatus(r.intent_id, s.status, JSON.stringify(s));
      } catch (e) {
        log('xchain_oneclick_failed', { step: 'status', err: (e as Error).message });
      }
    }
    const fresh = store.get(r.intent_id)!;
    const s = fresh.status_json ? (JSON.parse(fresh.status_json) as OneClickStatus) : null;
    return c.json({
      ...describe(fresh), intent_id: i.id, intent_status: i.status, tx_hash: i.tx_hash,
      status: mapStatus(i.status, s?.status ?? null), oneclick_status: s?.status ?? null, status_checked_at: fresh.status_at ? new Date(fresh.status_at).toISOString() : null,
      delivered_tx: s?.swapDetails?.destinationChainTxHashes ?? [], refunded_units: s?.swapDetails?.refundedAmount ?? null, refund_reason: s?.swapDetails?.refundReason ?? null,
    });
  });

  return { hooks };
}
