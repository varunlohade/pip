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
import { CHAINS, ORIGINS, checkAddress, findOrigin, findToken, relayAsset, type Origin, type TokenRow } from './assets.ts';
import { checkQuote, defaultLimits, quoteRequest, typedUnits, type Limits, type Mode, type Numbers } from './check.ts';
import { createChainDecimals, type ChainDecimals } from './decimals.ts';
import { chainName, parseXchain } from './parse.ts';
import { coingeckoSource, createOneClick, relaySource, type OneClick, type OneClickStatus, type PriceSource } from './sources.ts';
import { openXchainStore, type XchainRow } from './store.ts';
import { buildDeposit } from './tx.ts';
import { createNearViews, type NearViews } from './views.ts';

export type XchainDeps = { oneclick?: OneClick; prices?: PriceSource[]; chainDecimals?: ChainDecimals; views?: NearViews; limits?: Limits; mainnet?: MainnetConfig };

const QUOTE_MAX_AGE_MS = 60_000;
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

/** The default origin: the same stablecoin on NEAR when the destination is USDC or USDT, else NEAR. */
export const defaultOrigin = (token: string): Origin => (token === 'USDC' || token === 'USDT' ? token : 'NEAR');

/**
 * Pay any token on any chain from the user's NEAR account through NEAR Intents (1Click). Mainnet only.
 * A checked quote becomes a normal phone intent whose tx deposits the exact max input into 1Click's deposit account.
 */
export function xchainRoutes(app: Hono<Env>, base: { db: Db; now: () => number }, cfg: PayConfig = payConfig, deps: XchainDeps = {}): { hooks: XchainHooks } {
  const { db, now } = base;
  const main = deps.mainnet ?? mainnetConfig;
  const oneclick = deps.oneclick ?? createOneClick();
  const prices = deps.prices ?? [coingeckoSource(), relaySource(relayAsset), listSource];
  const chainDecimals = deps.chainDecimals ?? createChainDecimals();
  const views = deps.views ?? createNearViews(main.rpcUrl);
  const limits = deps.limits ?? defaultLimits();
  const phone = openPhoneStore(db, now);
  const networks = openNetworkStore(db, now);
  const store = openXchainStore(db, now);

  const json = async <T extends z.ZodTypeAny>(c: Context<Env>, schema: T): Promise<z.infer<T>> => schema.parse(await c.req.json().catch(() => {
    throw new HttpError(400, 'body must be JSON');
  }));
  const priceAll = (t: TokenRow) => Promise.all(prices.map(async (s) => ({ source: s.name, price: await s.price(t).catch(() => null) })));

  const describe = (r: XchainRow) => {
    const n = JSON.parse(r.numbers_json) as Numbers;
    return {
      kind: 'xchain', route: 'NEAR Intents (1Click)', verified: true, mode: r.mode,
      destination: { chain: r.dest_chain, chain_name: chainName(r.dest_chain), recipient: r.dest_recipient, asset: r.dest_asset },
      amount_out: n.amount_out, min_amount_out: n.min_amount_out, max_amount_in: n.max_amount_in, min_amount_in: n.min_amount_in,
      fee: n.fee, rate: n.rate, usd: n.usd, eta_seconds: n.eta_seconds,
      deposit_address: r.deposit_address, refund_to: r.refund_to,
      quote_at: new Date(r.quote_at).toISOString(), quote_expires_at: new Date(r.quote_at + QUOTE_MAX_AGE_MS).toISOString(), deadline: new Date(r.deadline).toISOString(),
    };
  };

  const hooks: XchainHooks = {
    describe(id) {
      const r = store.get(id);
      return r ? describe(r) : null;
    },
    guard(i) {
      const r = store.get(i.id);
      if (!r) return null;
      return now() - r.quote_at > QUOTE_MAX_AGE_MS ? 'this quote is over 60 seconds old; get a new quote' : null;
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
    const account = phone.account(userId, 'mainnet');
    if (account?.status !== 'ready') return c.json({ error: 'register your key in the Pip app first' }, 409);
    const chain = body.chain.toLowerCase();
    if (!CHAINS[chain]) return c.json({ error: `Pip does not pay to ${body.chain} yet` }, 400);
    const addr = checkAddress(chain, body.recipient);
    if (!addr.ok) return c.json({ error: addr.reason }, 400);
    const token = body.token.toUpperCase();
    const from = body.from ?? defaultOrigin(token);
    if (chain === 'near' && token === from && (token === 'NEAR' || token === 'USDC')) return c.json({ error: 'same token on NEAR: use a plain payment (/v1/pay/intents)' }, 400);
    const mode: Mode = body.mode ?? 'exact_out';

    let list: TokenRow[];
    try {
      list = await oneclick.tokens();
    } catch (e) {
      log('xchain_oneclick_failed', { step: 'tokens', err: (e as Error).message });
      return c.json({ error: 'could not reach NEAR Intents; try again' }, 502);
    }
    const origin = findOrigin(list, from);
    if (!origin) return c.json({ error: `${from} on NEAR is not supported by NEAR Intents` }, 400);
    const found = findToken(list, token, chain);
    if (!found.ok) return c.json({ error: found.reason }, 400);
    const dest = found.token;
    if (dest.assetId === origin.assetId) return c.json({ error: 'same token on NEAR: use a plain payment' }, 400);
    const typed = typedUnits(body.amount, mode, origin, dest);
    if (!typed.ok) return c.json({ error: typed.reason }, 400);

    const at = now();
    const sent = quoteRequest({ mode, units: typed.units, origin, dest, recipient: body.recipient, refundTo: account.account_id, deadline: new Date(at + DEADLINE_MS), slippageBps: limits.slippageBps, dry: body.dry ?? false });
    const [liveIn, liveOut, pIn, pOut, q] = await Promise.all([
      chainDecimals(origin).catch(() => null), chainDecimals(dest).catch(() => null), priceAll(origin), priceAll(dest),
      oneclick.quote(sent).catch((e: Error) => e),
    ]);
    if (q instanceof Error) {
      log('xchain_oneclick_failed', { step: 'quote', err: q.message });
      return c.json({ error: `NEAR Intents could not quote this: ${q.message}` }, 502);
    }
    const v = checkQuote({ mode, typed: typed.units, origin, dest, chainDecimals: { origin: liveIn, dest: liveOut }, sent, q, prices: { origin: pIn, dest: pOut }, limits, now: at, minDeadlineMs: DEADLINE_MARGIN_MS + cfg.intentTtlMs });
    log('xchain_quote', {
      user_id: userId, mode, chain, typed_text: body.amount, typed_units: typed.units.toString(), origin: origin.assetId, dest: dest.assetId,
      amount_in: v.numbers?.amount_in.text ?? null, amount_in_units: q.quote?.amountIn ?? null, amount_out: v.numbers?.amount_out.text ?? null, amount_out_units: q.quote?.amountOut ?? null,
      fee_usd: v.numbers?.fee.usd ?? null, verified: v.verified, refused: v.ok ? null : v.refused, correlation_id: q.correlationId,
    });
    if (!v.ok) {
      if (v.refused) return c.json({ error: v.refused, verified: false, numbers: v.numbers }, 422);
      return c.json({ verified: false, not_verified: v.not_verified, numbers: v.numbers, intent: null });
    }
    const destination = { chain, chain_name: chainName(chain), recipient: body.recipient };
    if (body.dry) return c.json({ verified: true, dry: true, numbers: v.numbers, destination, route: 'NEAR Intents (1Click)', refund_to: account.account_id, intent: null });

    // Caps on the max input, in the origin token, with the same per-network limits as plain sends.
    const tok = from as Token;
    const units = BigInt(q.quote.amountIn);
    const amount = v.numbers.amount_in.text;
    if (toUnits(amount, tok) !== units) return c.json({ error: 'decimals for the origin token disagree with the wallet' }, 422);
    const cap = main.caps[tok];
    if (units > toUnits(cap.perTx, tok)) return c.json({ error: `over the ${cap.perTx} ${tok} limit per payment`, verified: true, numbers: v.numbers }, 403);
    if (phone.spentSince(userId, 'mainnet', tok, at - DAY) + units > toUnits(cap.daily, tok)) return c.json({ error: `over the ${cap.daily} ${tok} daily limit`, verified: true, numbers: v.numbers }, 403);

    const deadline = Date.parse(q.quote.deadline!);
    const id = randomBytes(16).toString('hex');
    db.tx(() => {
      phone.addIntent({
        id, user_id: userId, network: 'mainnet', token: tok, amount, units: units.toString(), recipient: q.quote.depositAddress!,
        new_recipient: 1, created_at: at, expires_at: Math.min(at + cfg.intentTtlMs, deadline - DEADLINE_MARGIN_MS),
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
