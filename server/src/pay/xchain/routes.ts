import type { Context, Hono } from 'hono';
import { randomBytes } from 'node:crypto';
import { z } from 'zod';
import type { Db } from '../../db.ts';
import { HttpError, type Env } from '../../http.ts';
import { log } from '../../log.ts';
import { payConfig, type PayConfig, type Token } from '../config.ts';
import { mainnetConfig, openNetworkStore, type MainnetConfig } from '../network.ts';
import { toUnits } from '../parse.ts';
import { openPhoneStore, type PhoneIntent } from '../phone/store.ts';
import type { XchainHooks } from '../phone/routes.ts';
import { CHAINS, ORIGINS, checkAddress, findOrigin, findToken, type Origin, type TokenRow } from './assets.ts';
import { checkPin, type Pin } from './pins.ts';
import { checkQuote, defaultLimits, quoteRequest, typedUnits, type Limits, type Mode, type Numbers } from './check.ts';
import { createChainDecimals, type ChainDecimals } from './decimals.ts';
import { chainName, parseXchain } from './parse.ts';
import { coingeckoSource, createOneClick, relaySource, type OneClick, type OneClickStatus, type PriceSource } from './sources.ts';
import { openXchainStore, type XchainRow } from './store.ts';
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
const DAY = 86_400_000;

const Quote = z.object({
  amount: z.string().max(40), token: z.string().max(12), chain: z.string().max(16), recipient: z.string().max(100),
  from: z.enum(['NEAR', 'USDC', 'USDT']).optional(), mode: z.enum(['exact_out', 'exact_in']).optional(), dry: z.boolean().optional(),
}).strict();
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

  const json = async <T extends z.ZodTypeAny>(c: Context<Env>, schema: T): Promise<z.infer<T>> => schema.parse(await c.req.json().catch(() => {
    throw new HttpError(400, 'body must be JSON');
  }));
  const priceAll = (t: TokenRow, pin: Pin) => Promise.all(prices.map(async (s) => ({ source: s.name, price: await s.price(t, pin).catch(() => null) })));

  const describe = (r: XchainRow) => {
    const n = JSON.parse(r.numbers_json) as Numbers;
    return {
      kind: 'xchain', route: 'NEAR Intents (1Click)', verified: true, mode: r.mode,
      destination: { chain: r.dest_chain, chain_name: chainName(r.dest_chain), recipient: r.dest_recipient, asset: r.dest_asset, first_time: !store.paidBefore(r) },
      amount_out: n.amount_out, min_amount_out: n.min_amount_out, max_amount_in: n.max_amount_in, min_amount_in: n.min_amount_in,
      fee: n.fee, rate: n.rate, usd: n.usd, eta_seconds: n.eta_seconds,
      deposit_address: r.deposit_address, refund_to: r.refund_to,
      quote_at: new Date(r.quote_at).toISOString(), quote_expires_at: new Date(r.quote_at + QUOTE_MAX_AGE_MS).toISOString(), deadline: new Date(r.deadline).toISOString(),
    };
  };

  type Input = { amount: string; token: string; chain: string; recipient: string; from?: Origin; mode?: Mode; dry?: boolean };
  type Fail = { ok: false; status: 200 | 400 | 403 | 409 | 422 | 502; body: Record<string, unknown> };
  const fail = (status: Fail['status'], error: string, extra: Record<string, unknown> = {}): Fail => ({ ok: false, status, body: { error, ...extra } });
  const answer = (body: Record<string, unknown>): Fail => ({ ok: false, status: 200, body });

  /** Validates, quotes and checks one payment, then applies the caps. Shared by /quote and the re-quote before signing. */
  async function runQuote(userId: string, body: Input) {
    const account = phone.account(userId, 'mainnet');
    if (account?.status !== 'ready') return fail(409, 'register your key in the Pip app first');
    const chain = body.chain.toLowerCase();
    if (!CHAINS[chain]) return fail(400, `Pip does not pay to ${body.chain} yet`);
    const addr = checkAddress(chain, body.recipient);
    if (!addr.ok) return fail(400, addr.reason);
    const token = body.token.toUpperCase();
    const from = body.from ?? defaultOrigin(token, chain);
    if (chain === 'near' && token === from && (token === 'NEAR' || token === 'USDC')) return fail(400, 'same token on NEAR: use a plain payment (/v1/pay/intents)');
    // A named NEAR account must exist, as for plain sends. An implicit id may not exist yet.
    if (chain === 'near' && !/^[0-9a-f]{64}$/.test(body.recipient)) {
      const exists = await views.accountExists(body.recipient).catch((e: Error) => {
        log('pay_rpc_failed', { network: 'mainnet', err: e.message });
        return undefined;
      });
      if (exists === undefined) return fail(502, 'could not reach NEAR mainnet; try again');
      if (!exists) return fail(400, `${body.recipient} does not exist on mainnet`);
    }
    const mode: Mode = body.mode ?? 'exact_out';

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
    const pins: Pin[] = [];
    for (const t of [origin, dest]) {
      const p = checkPin(t);
      if (!p.ok) return p.refused ? fail(422, p.refused, { verified: false }) : answer({ verified: false, not_verified: [p.reason], numbers: null, intent: null });
      pins.push(p.pin);
    }
    const typed = typedUnits(body.amount, mode, origin, dest);
    if (!typed.ok) return fail(400, typed.reason);

    const at = now();
    const sent = quoteRequest({ mode, units: typed.units, origin, dest, recipient: body.recipient, refundTo: account.account_id, deadline: new Date(at + DEADLINE_MS), slippageBps: limits.slippageBps, dry: body.dry ?? false });
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
      user_id: userId, mode, chain, typed_text: body.amount, typed_units: typed.units.toString(), origin: origin.assetId, dest: dest.assetId,
      amount_in: v.numbers?.amount_in.text ?? null, amount_in_units: q.quote?.amountIn ?? null, amount_out: v.numbers?.amount_out.text ?? null, amount_out_units: q.quote?.amountOut ?? null,
      fee_usd: v.numbers?.fee.usd ?? null, verified: v.verified, refused: v.ok ? null : v.refused, correlation_id: q.correlationId,
    });
    if (!v.ok) {
      if (v.refused) return fail(422, v.refused, { verified: false, numbers: v.numbers });
      return answer({ verified: false, not_verified: v.not_verified, numbers: v.numbers, intent: null });
    }
    const destination = { chain, chain_name: chainName(chain), recipient: body.recipient };
    if (body.dry) return answer({ verified: true, dry: true, numbers: v.numbers, destination, route: 'NEAR Intents (1Click)', refund_to: account.account_id, intent: null });

    // Caps on the max input, in the origin token, with the same per-network limits as plain sends.
    const tok = from as Token;
    const units = BigInt(q.quote.amountIn);
    const amount = v.numbers.amount_in.text;
    if (toUnits(amount, tok) !== units) return fail(422, 'decimals for the origin token disagree with the wallet');
    const cap = main.caps[tok];
    if (units > toUnits(cap.perTx, tok)) return fail(403, `over the ${cap.perTx} ${tok} limit per payment`, { verified: true, numbers: v.numbers });
    if (phone.spentSince(userId, 'mainnet', tok, at - DAY) + units > toUnits(cap.daily, tok)) return fail(403, `over the ${cap.daily} ${tok} daily limit`, { verified: true, numbers: v.numbers });
    return { ok: true as const, v, q, origin, dest, at, tok, units, amount, account, chain, mode, deadline: Date.parse(q.quote.deadline!) };
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
      });
      if (!res.ok) {
        const why = String(res.body.error ?? (res.body.not_verified as string[] | undefined)?.join('; ') ?? 'not verified');
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

  app.post('/v1/pay/xchain/parse', async (c) => c.json({ ...parseXchain((await json(c, ParseBody)).text), source: 'regex' }));

  app.post('/v1/pay/xchain/quote', async (c) => {
    const userId = c.get('userId');
    if (networks.get(userId) !== 'mainnet') return c.json({ error: 'cross-chain payments run on mainnet only; NEAR Intents has no testnet' }, 409);
    if (!main.enabled) return c.json({ error: 'mainnet payments are off on this server' }, 503);
    const body = await json(c, Quote);
    const res = await runQuote(userId, body);
    if (!res.ok) return c.json(res.body, res.status);
    const { v, q, origin, dest, at, tok, units, amount, account, chain, mode, deadline } = res;
    const id = randomBytes(16).toString('hex');
    db.tx(() => {
      phone.addIntent({
        id, user_id: userId, network: 'mainnet', token: tok, amount, units: units.toString(), recipient: q.quote.depositAddress!,
        new_recipient: 1, created_at: at, expires_at: Math.min(at + SIGN_WINDOW_MS, deadline - DEADLINE_MARGIN_MS),
      });
      store.add({
        intent_id: id, user_id: userId, origin_asset: origin.assetId, dest_asset: dest.assetId, dest_chain: chain, dest_recipient: body.recipient,
        deposit_address: q.quote.depositAddress!, refund_to: account.account_id, mode, numbers_json: JSON.stringify(v.numbers), quote_json: JSON.stringify(q), quote_at: at, deadline,
      });
    });
    const i = phone.intent(id)!;
    return c.json({
      ...describe(store.get(id)!),
      intent: { id, amount: i.amount, token: i.token, recipient: i.recipient, status: i.status, network: 'mainnet', expires_at: new Date(i.expires_at).toISOString(), deep_link: `pip://approve/${id}` },
    }, 201);
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
