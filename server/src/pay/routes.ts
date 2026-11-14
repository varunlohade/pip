import type { Context, Hono } from 'hono';
import { randomBytes, timingSafeEqual } from 'node:crypto';
import { z } from 'zod';
import type { Cipher } from '../crypto.ts';
import { randomToken, sha256 } from '../crypto.ts';
import type { Db } from '../db.ts';
import { HttpError, type Env } from '../http.ts';
import { log } from '../log.ts';
import { createNearChain, type Chain } from './chain.ts';
import { payConfig, type PayConfig } from './config.ts';
import { checkPayment, fromUnits, parsePayment, toUnits, type ParseResult } from './parse.ts';
import { openPayStore, type Intent } from './store.ts';

export type PayDeps = {
  chain?: Chain;
  config?: PayConfig;
  /** Reads a payment the fixed patterns missed (a model call). Its answer passes the same checks; it can only propose. */
  fallback?: (text: string) => Promise<{ amount: string; token: string; recipient: string } | null>;
};

const ParseBody = z.object({ text: z.string().trim().min(1).max(500) }).strict();
const Fields = z.object({ amount: z.string().max(40), token: z.string().max(8), recipient: z.string().max(80) }).strict();
const IntentId = z.string().regex(/^[0-9a-f]{32}$/);
const DAY = 86_400_000;

export function payRoutes(app: Hono<Env>, base: { db: Db; cipher: Cipher; now: () => number }, deps: PayDeps = {}) {
  const { db, cipher, now } = base;
  const cfg = deps.config ?? payConfig;
  const chain = deps.chain ?? createNearChain(cfg);
  const store = openPayStore(db, now);
  const notReady = (c: Context<Env>) =>
    (!cfg.funderAccountId || !cfg.funderSecretKey ? c.json({ error: 'payments are not set up on this server' }, 503) : undefined);
  const json = async <T extends z.ZodTypeAny>(c: Context<Env>, schema: T): Promise<z.infer<T>> => schema.parse(await c.req.json().catch(() => {
    throw new HttpError(400, 'body must be JSON');
  }));
  const explorer = (hash: string | null) => (hash ? `${cfg.explorerTx}${hash}` : null);
  const view = (i: Intent) => ({
    id: i.id, amount: i.amount, token: i.token, recipient: i.recipient, status: i.status, network: cfg.network,
    expires_at: new Date(i.expires_at).toISOString(), tx_hash: i.tx_hash, explorer_url: explorer(i.tx_hash), deep_link: `pip://approve/${i.id}`,
  });
  /** True or false from the RPC; undefined when the RPC could not answer. */
  const exists = async (recipient: string) => {
    try {
      return await chain.accountExists(recipient);
    } catch (e) {
      log('pay_rpc_failed', { err: (e as Error).message });
      return undefined;
    }
  };
  const rpcDown = (c: Context<Env>) => c.json({ error: 'could not reach NEAR testnet; try again' }, 502);

  // ---- parse: fixed patterns first; a fallback reader only when they find nothing. No money moves here.
  app.post('/v1/pay/parse', async (c) => {
    const { text } = await json(c, ParseBody);
    let r: ParseResult = parsePayment(text);
    let source = 'regex';
    if (!r.valid && deps.fallback && r.reason.startsWith('no payment found')) {
      const guess = await deps.fallback(text).catch(() => null);
      if (guess) {
        r = checkPayment(guess);
        source = 'fallback';
      }
    }
    if (r.valid) {
      const found = await exists(r.recipient);
      if (found === undefined) return rpcDown(c);
      if (!found) r = { valid: false, reason: `${r.recipient} does not exist on testnet` };
    }
    log('pay_parse', { user_id: c.get('userId'), valid: r.valid, source });
    return c.json({ ...r, source, network: cfg.network });
  });

  // ---- the wallet: one testnet sub-account per user, made on first look. The server holds its key, encrypted.
  app.get('/v1/pay/wallet', async (c) => {
    const off = notReady(c);
    if (off) return off;
    const userId = c.get('userId');
    let w = store.wallet(userId);
    if (w?.status === 'failed') {
      store.dropFailedWallet(userId);
      w = undefined;
    }
    if (!w) {
      if (store.walletCount() >= cfg.maxWallets) return c.json({ error: 'no new wallets right now' }, 503);
      const accountId = `pip-${cipher.lookupHash('pay-wallet', userId).slice(0, 12)}.${cfg.funderAccountId}`;
      const key = chain.newKey();
      if (store.claimWallet(userId, accountId, cipher.encrypt(userId, key.secretKey))) {
        try {
          const tx = await chain.createAccount(accountId, key.publicKey, toUnits(cfg.newWalletNear, 'NEAR'));
          store.finishWallet(userId, 'ready', tx);
          store.audit(userId, null, 'wallet_created');
          log('pay_wallet', { user_id: userId, ok: true });
        } catch (e) {
          store.finishWallet(userId, 'failed', null);
          log('pay_wallet', { user_id: userId, ok: false, err: (e as Error).message });
          return c.json({ error: 'could not create the wallet; try again' }, 502);
        }
      }
      w = store.wallet(userId)!;
    }
    if (w.status !== 'ready') return c.json({ account_id: w.account_id, status: w.status, network: cfg.network }, 202);
    const b = await chain.balances(w.account_id).catch(() => undefined);
    if (!b) return rpcDown(c);
    return c.json({
      account_id: w.account_id, status: 'ready', network: cfg.network,
      balances: { NEAR: fromUnits(b.NEAR, 'NEAR'), USDC: fromUnits(b.USDC, 'USDC') },
      caps: cfg.caps,
    });
  });

  // ---- the approver key: made by the app once, kept in the app's own Keychain behind Face ID, never shared with the keyboard.
  // A new key replaces the old one only with the old key, or when the session that made it is gone (signed out, new phone).
  app.post('/v1/pay/approver', async (c) => {
    const userId = c.get('userId');
    const old = store.approver(userId);
    if (old && store.sessionAlive(old.session_id) && !approverOk(c, old.key_hash)) return c.json({ error: 'an approver is already set up' }, 409);
    const key = randomToken('pap');
    store.setApprover(userId, sha256(key), c.get('sessionId'));
    store.audit(userId, null, old ? 'approver_replaced' : 'approver_created');
    return c.json({ approver_key: key });
  });

  // ---- intents: a proposal with exact fields and a 10-minute life. Anyone with the user's token can propose; only the approver can approve.
  app.post('/v1/pay/intents', async (c) => {
    const userId = c.get('userId');
    const r = checkPayment(await json(c, Fields));
    if (!r.valid) return c.json({ error: r.reason }, 400);
    const units = toUnits(r.amount, r.token);
    if (units > toUnits(cfg.caps[r.token].perTx, r.token)) return c.json({ error: `over the ${cfg.caps[r.token].perTx} ${r.token} limit per payment` }, 400);
    const found = await exists(r.recipient);
    if (found === undefined) return rpcDown(c);
    if (!found) return c.json({ error: `${r.recipient} does not exist on testnet` }, 400);
    const at = now();
    const id = randomBytes(16).toString('hex');
    store.addIntent({ id, user_id: userId, token: r.token, amount: r.amount, units: units.toString(), recipient: r.recipient, created_at: at, expires_at: at + cfg.intentTtlMs });
    store.audit(userId, id, 'proposed');
    log('pay_intent', { user_id: userId, intent_id: id, token: r.token });
    return c.json(view(store.intent(id)!), 201);
  });

  const owned = (c: Context<Env>) => {
    const id = IntentId.safeParse(c.req.param('id'));
    const i = id.success ? store.intent(id.data) : undefined;
    if (!i || i.user_id !== c.get('userId')) throw new HttpError(404, 'no such payment');
    return i;
  };
  const expireIfDue = (i: Intent) => {
    if (i.status === 'pending' && i.expires_at <= now() && store.move(i.id, 'pending', 'expired', { decidedAt: now() })) store.audit(i.user_id, i.id, 'expired');
    return store.intent(i.id)!;
  };

  app.get('/v1/pay/intents/:id', (c) => c.json(view(expireIfDue(owned(c)))));

  app.post('/v1/pay/intents/:id/reject', async (c) => {
    const i = expireIfDue(owned(c));
    if (i.status === 'pending' && store.move(i.id, 'pending', 'rejected', { decidedAt: now() })) store.audit(i.user_id, i.id, 'rejected');
    const after = store.intent(i.id)!;
    if (after.status !== 'rejected') return c.json({ error: `this payment is ${after.status}`, ...view(after) }, 409);
    return c.json(view(after));
  });

  // ---- approve: the app only (approver key), the exact fields the card showed, caps, then one send. Twice never sends twice.
  app.post('/v1/pay/intents/:id/approve', async (c) => {
    const off = notReady(c);
    if (off) return off;
    const userId = c.get('userId');
    const appr = store.approver(userId);
    if (!appr || !approverOk(c, appr.key_hash)) {
      log('pay_approve_denied', { user_id: userId });
      return c.json({ error: 'approve in the Pip app' }, 403);
    }
    const fields = await json(c, Fields);
    let i = expireIfDue(owned(c));
    if (i.status !== 'pending') {
      if (i.status === 'expired') return c.json({ error: 'this payment expired; start again', ...view(i) }, 410);
      if (i.status === 'rejected') return c.json({ error: 'this payment was declined', ...view(i) }, 409);
      return c.json(view(i));
    }
    if (fields.amount !== i.amount || fields.token !== i.token || fields.recipient !== i.recipient) {
      return c.json({ error: 'the details do not match this payment' }, 409);
    }
    const w = store.wallet(userId);
    if (w?.status !== 'ready') return c.json({ error: 'open your wallet first' }, 409);
    const units = BigInt(i.units);
    const claim = db.tx(() => {
      const cap = cfg.caps[i.token];
      if (units > toUnits(cap.perTx, i.token)) return `over the ${cap.perTx} ${i.token} limit per payment`;
      if (store.spentSince(userId, i.token, now() - DAY) + units > toUnits(cap.daily, i.token)) return `over the ${cap.daily} ${i.token} daily limit`;
      return store.move(i.id, 'pending', 'sending', { decidedAt: now() }) ? 'ok' : 'lost';
    });
    if (claim === 'lost') return c.json(view(store.intent(i.id)!));
    if (claim !== 'ok') {
      store.audit(userId, i.id, 'cap_blocked');
      return c.json({ error: claim }, 403);
    }
    store.audit(userId, i.id, 'approved');
    let prepared;
    try {
      prepared = await chain.prepareSend({ accountId: w.account_id, secretKey: cipher.decrypt(userId, w.key_enc) }, i.token, i.recipient, units);
      store.move(i.id, 'sending', 'sending', { txHash: prepared.hash });
    } catch (e) {
      // Nothing was broadcast, so nothing left the wallet.
      store.move(i.id, 'sending', 'failed');
      store.audit(userId, i.id, 'failed_before_send');
      log('pay_send', { user_id: userId, intent_id: i.id, ok: false, err: (e as Error).message });
      return c.json({ error: 'could not send; nothing left your wallet', ...view(store.intent(i.id)!) }, 502);
    }
    let outcome: 'sent' | 'failed' | 'outcome_unknown';
    try {
      outcome = (await prepared.broadcast()) === 'ok' ? 'sent' : 'failed';
    } catch (e) {
      // It may have landed. Never retried; the hash lets anyone check.
      outcome = 'outcome_unknown';
      log('pay_send_unknown', { user_id: userId, intent_id: i.id, err: (e as Error).message });
    }
    store.move(i.id, 'sending', outcome);
    store.audit(userId, i.id, outcome);
    log('pay_send', { user_id: userId, intent_id: i.id, ok: outcome === 'sent', outcome });
    i = store.intent(i.id)!;
    return c.json(view(i), outcome === 'sent' ? 200 : outcome === 'failed' ? 502 : 202);
  });

  app.get('/v1/pay/history', (c) => c.json({ payments: store.history(c.get('userId'), 50).map((i) => view(expireIfDue(i))) }));
}

function approverOk(c: Context<Env>, keyHash: string): boolean {
  const got = c.req.header('x-pay-approver');
  if (!got || !/^pap_[A-Za-z0-9_-]{20,100}$/.test(got)) return false;
  const a = Buffer.from(sha256(got)), b = Buffer.from(keyHash);
  return a.length === b.length && timingSafeEqual(a, b);
}
