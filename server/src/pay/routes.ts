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
import type { PhoneDeps } from './phone/routes.ts';
import type { XchainDeps } from './xchain/routes.ts';

export type PayDeps = {
  chain?: Chain;
  config?: PayConfig;
  /** Reads a payment the fixed patterns missed (a model call). Its answer passes the same checks; it can only propose. */
  fallback?: (text: string) => Promise<{ amount: string; token: string; recipient: string } | null>;
  /** The phone-signed flow (src/pay/phone): fake chains and mainnet settings for tests. */
  phone?: PhoneDeps;
  /** Cross-chain payments (src/pay/xchain): fake 1Click, prices, decimals and NEAR views for tests. */
  xchain?: XchainDeps;
};

const ParseBody = z.object({ text: z.string().trim().min(1).max(500) }).strict();
const Fields = z.object({ amount: z.string().max(40), token: z.string().max(8), recipient: z.string().max(80) }).strict();
const IntentId = z.string().regex(/^[0-9a-f]{32}$/);
const KeyboardLimits = z.object({ usdc_daily: z.string().max(20), near_daily: z.string().max(40) }).strict();
const DAY = 86_400_000;

export function payRoutes(app: Hono<Env>, base: { db: Db; cipher: Cipher; now: () => number }, deps: PayDeps = {}) {
  const { db, cipher, now } = base;
  const cfg = deps.config ?? payConfig;
  const chain = deps.chain ?? createNearChain(cfg);
  const store = openPayStore(db, now);
  const notReady = (c: Context<Env>) =>
    (!cfg.legacyCustody ? c.json({ error: 'server-held wallets are off; the Pip app signs payments' }, 410)
      : !cfg.funderAccountId || !cfg.funderSecretKey ? c.json({ error: 'payments are not set up on this server' }, 503) : undefined);
  const json = async <T extends z.ZodTypeAny>(c: Context<Env>, schema: T): Promise<z.infer<T>> => schema.parse(await c.req.json().catch(() => {
    throw new HttpError(400, 'body must be JSON');
  }));
  const explorer = (hash: string | null) => (hash ? `${cfg.explorerTx}${hash}` : null);
  const view = (i: Intent) => ({
    id: i.id, amount: i.amount, token: i.token, recipient: i.recipient, status: i.status, network: cfg.network,
    expires_at: new Date(i.expires_at).toISOString(), tx_hash: i.tx_hash, explorer_url: explorer(i.tx_hash), deep_link: `pip://approve/${i.id}`,
    ...(i.status === 'pending' ? { keyboard: keyboardCheck(i) } : {}),
  });
  /**
   * May the keyboard key send this? Only to someone this user paid before, and only within the keyboard's daily limit
   * (and the server caps). Anything else opens the app. `left` is what the keyboard may still send today in this token.
   */
  function keyboardCheck(i: Intent): { ok: boolean; reason?: 'not_set_up' | 'new_recipient' | 'over_limit'; left?: string; paid_before: number } {
    const kb = store.keyboard(i.user_id);
    const paid = store.paidBefore(i.user_id, i.recipient);
    if (!kb) return { ok: false, reason: 'not_set_up', paid_before: paid };
    const limit = BigInt(i.token === 'USDC' ? kb.usdc_daily : kb.near_daily);
    const spent = store.keyboardSpentSince(i.user_id, i.token, now() - DAY);
    const leftUnits = limit > spent ? limit - spent : 0n;
    const left = fromUnits(leftUnits, i.token);
    if (paid === 0) return { ok: false, reason: 'new_recipient', left, paid_before: 0 };
    if (BigInt(i.units) > leftUnits) return { ok: false, reason: 'over_limit', left, paid_before: paid };
    return { ok: true, left, paid_before: paid };
  }
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

  // ---- the keyboard key: made by the app (approver key needed) with the owner's daily limits. It lives in the shared
  // Keychain group, so the keyboard (or anything that steals it) can only send small amounts to people paid before.
  app.post('/v1/pay/keyboard', async (c) => {
    const userId = c.get('userId');
    const appr = store.approver(userId);
    if (!appr || !approverOk(c, appr.key_hash)) return c.json({ error: 'set this up in the Pip app' }, 403);
    const body = await json(c, KeyboardLimits);
    const limits = { USDC: body.usdc_daily, NEAR: body.near_daily } as const;
    const units = { USDC: 0n, NEAR: 0n };
    for (const t of ['USDC', 'NEAR'] as const) {
      if (!/^\d{1,12}(\.\d+)?$/.test(limits[t])) return c.json({ error: `write the ${t} limit as a plain number` }, 400);
      units[t] = toUnits(limits[t], t);
      // The keyboard limit never goes above the server's own daily cap.
      const cap = toUnits(cfg.caps[t].daily, t);
      if (units[t] > cap) units[t] = cap;
    }
    const key = randomToken('pkb');
    store.setKeyboard(userId, sha256(key), units.USDC, units.NEAR);
    store.audit(userId, null, 'keyboard_key_set');
    return c.json({ keyboard_key: key, limits: { USDC: fromUnits(units.USDC, 'USDC'), NEAR: fromUnits(units.NEAR, 'NEAR') } });
  });

  app.delete('/v1/pay/keyboard', (c) => {
    const userId = c.get('userId');
    const appr = store.approver(userId);
    if (!appr || !approverOk(c, appr.key_hash)) return c.json({ error: 'set this up in the Pip app' }, 403);
    store.dropKeyboard(userId);
    store.audit(userId, null, 'keyboard_key_dropped');
    return c.json({ ok: true });
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
    return approveAndSend(c, 'app');
  });

  // ---- keyboard approve: the capped keyboard key. A new recipient or a send over the keyboard limit gets 403 with
  // needs_app, and the keyboard opens the app instead.
  app.post('/v1/pay/intents/:id/keyboard-approve', async (c) => {
    const off = notReady(c);
    if (off) return off;
    const userId = c.get('userId');
    const kb = store.keyboard(userId);
    const got = c.req.header('x-pay-keyboard');
    if (!kb || !got || !/^pkb_[A-Za-z0-9_-]{20,100}$/.test(got) || !sameHash(sha256(got), kb.key_hash)) {
      log('pay_keyboard_denied', { user_id: userId });
      return c.json({ error: 'approve in the Pip app', needs_app: true }, 403);
    }
    return approveAndSend(c, 'keyboard');
  });

  async function approveAndSend(c: Context<Env>, via: 'app' | 'keyboard') {
    const userId = c.get('userId');
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
      // Checked inside the same transaction as the claim, so two keyboard sends at once cannot both pass the limit.
      if (via === 'keyboard') {
        const k = keyboardCheck(i);
        if (!k.ok) return k.reason === 'new_recipient' ? 'new recipient: approve in the Pip app' : 'over the keyboard limit: approve in the Pip app';
      }
      return store.move(i.id, 'pending', 'sending', { decidedAt: now(), via }) ? 'ok' : 'lost';
    });
    if (claim === 'lost') return c.json(view(store.intent(i.id)!));
    if (claim !== 'ok') {
      store.audit(userId, i.id, via === 'keyboard' ? 'keyboard_blocked' : 'cap_blocked');
      return c.json({ error: claim, ...(via === 'keyboard' ? { needs_app: true } : {}) }, 403);
    }
    store.audit(userId, i.id, via === 'keyboard' ? 'approved_keyboard' : 'approved');
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
  }

  app.get('/v1/pay/history', (c) => c.json({ payments: store.history(c.get('userId'), 50).map((i) => view(expireIfDue(i))) }));
}

export function approverOk(c: Context<Env>, keyHash: string): boolean {
  const got = c.req.header('x-pay-approver');
  if (!got || !/^pap_[A-Za-z0-9_-]{20,100}$/.test(got)) return false;
  return sameHash(sha256(got), keyHash);
}

function sameHash(x: string, y: string): boolean {
  const a = Buffer.from(x), b = Buffer.from(y);
  return a.length === b.length && timingSafeEqual(a, b);
}
