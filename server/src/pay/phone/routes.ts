import type { Context, Hono } from 'hono';
import { randomBytes } from 'node:crypto';
import { baseEncode } from 'near-api-js';
import { z } from 'zod';
import type { Db } from '../../db.ts';
import { HttpError, type Env } from '../../http.ts';
import { log } from '../../log.ts';
import { payConfig, type PayConfig } from '../config.ts';
import { mainnetConfig, openNetworkStore, recipientRule, settingsFor, type MainnetConfig, type Network } from '../network.ts';
import { checkPayment, fromUnits, parsePayment, toUnits, type ParseResult } from '../parse.ts';
import { approverOk } from '../routes.ts';
import { openPayStore } from '../store.ts';
import { createPhoneChain, type PhoneChain } from './chain.ts';
import { openPhoneStore, type PhoneIntent } from './store.ts';
import { buildTransfer, implicitAccountId, nearPublicKey, parsePublicKey, parseSignature, sha256, signedBytes, verifySignature } from './tx.ts';

/** Cross-chain payments (src/pay/xchain) ride on this flow: they describe their card, may refuse a build, and build their own deposit tx. */
export type XchainHooks = {
  describe(intentId: string): Record<string, unknown> | null;
  /** Before a build: re-quotes an old quote onto the intent (requoted: true), or says why it cannot (status + error). */
  refresh(i: PhoneIntent): Promise<{ status: 403 | 409 | 422 | 502 | 400; error: string } | { requoted: boolean }>;
  /** The deposit transaction for an xchain intent, or null when the intent is not xchain. */
  build(i: PhoneIntent, ctx: { signerId: string; publicKey: Uint8Array; nonce: bigint; blockHash: string }): Promise<{ bytes: Uint8Array; hash: Uint8Array } | null>;
};
export type PhoneDeps = { chains?: Partial<Record<Network, PhoneChain>>; mainnet?: MainnetConfig; xchain?: XchainHooks };

const Fields = z.object({ amount: z.string().max(40), token: z.string().max(8), recipient: z.string().max(80) }).strict();
const ParseBody = z.object({ text: z.string().trim().min(1).max(500) }).strict();
const Register = z.object({ publicKey: z.string().max(80) }).strict();
const Switch = z.object({ network: z.enum(['testnet', 'mainnet']) }).strict();
const Submit = z.object({ signature: z.string().max(140) }).strict();
const IntentId = z.string().regex(/^[0-9a-f]{32}$/);
const DAY = 86_400_000;

/**
 * Phone-signed payments on testnet and mainnet. The phone holds the key; the server builds the exact transaction,
 * checks the phone's signature against it, and broadcasts. Registered before the legacy routes: a handler calls next()
 * when the request belongs to the legacy server-held path.
 */
export function phoneRoutes(app: Hono<Env>, base: { db: Db; now: () => number }, cfg: PayConfig = payConfig, deps: PhoneDeps = {}) {
  const { db, now } = base;
  const main = deps.mainnet ?? mainnetConfig;
  const store = openPhoneStore(db, now);
  const pay = openPayStore(db, now);
  const networks = openNetworkStore(db, now);
  const chains: Partial<Record<Network, PhoneChain>> = { ...deps.chains };
  const chainFor = (n: Network) => (chains[n] ??= createPhoneChain(settingsFor(n, cfg, main), n === 'testnet' ? { accountId: cfg.funderAccountId, secretKey: cfg.funderSecretKey } : undefined));
  const settings = (n: Network) => settingsFor(n, cfg, main);

  const json = async <T extends z.ZodTypeAny>(c: Context<Env>, schema: T): Promise<z.infer<T>> => schema.parse(await c.req.json().catch(() => {
    throw new HttpError(400, 'body must be JSON');
  }));
  const isApp = (c: Context<Env>) => {
    const a = pay.approver(c.get('userId'));
    return !!a && approverOk(c, a.key_hash);
  };
  const phoneMode = (userId: string) => networks.get(userId) === 'mainnet' || !cfg.legacyCustody || !!store.account(userId, 'testnet');
  const mainnetOff = (c: Context<Env>, n: Network) => (n === 'mainnet' && !main.enabled ? c.json({ error: 'mainnet payments are off on this server' }, 503) : undefined);
  const rpcDown = (c: Context<Env>, n: Network) => c.json({ error: `could not reach NEAR ${n}; try again` }, 502);
  const check = (n: Network) => (p: { amount: string; token: string; recipient: string }) => checkPayment(p, recipientRule(n));
  const view = (i: PhoneIntent) => ({
    id: i.id, amount: i.amount, token: i.token, recipient: i.recipient, status: i.status, network: i.network, signing: 'phone',
    new_recipient: i.new_recipient === 1, expires_at: new Date(i.expires_at).toISOString(),
    tx_hash: i.tx_hash, explorer_url: i.tx_hash && ['sending', 'sent', 'failed', 'outcome_unknown'].includes(i.status) ? `${settings(i.network).explorerTx}${i.tx_hash}` : null,
    deep_link: `pip://approve/${i.id}`, xchain: deps.xchain?.describe(i.id) ?? null,
  });
  /** Named accounts must exist. An implicit id may not exist yet: a NEAR transfer creates it. Undefined when the RPC failed. */
  const recipientOk = async (n: Network, recipient: string) => {
    if (/^[0-9a-f]{64}$/.test(recipient)) return true;
    try {
      return await chainFor(n).accountExists(recipient);
    } catch (e) {
      log('pay_rpc_failed', { network: n, err: (e as Error).message });
      return undefined;
    }
  };

  // ---- network: testnet by default. Only the app (approver key) switches it.
  app.get('/v1/pay/network', (c) => {
    const userId = c.get('userId');
    const n = networks.get(userId);
    const a = store.account(userId, n);
    return c.json({ network: n, mainnet_enabled: main.enabled, account_id: a?.account_id ?? null, caps: settings(n).caps });
  });
  app.put('/v1/pay/network', async (c) => {
    const userId = c.get('userId');
    if (!isApp(c)) return c.json({ error: 'switch networks in the Pip app' }, 403);
    const { network } = await json(c, Switch);
    const off = mainnetOff(c, network);
    if (off) return off;
    networks.set(userId, network);
    pay.audit(userId, null, `network_${network}`);
    return c.json({ network, account_id: store.account(userId, network)?.account_id ?? null });
  });

  // ---- register: the app sends its Ed25519 public key; the account is the implicit id of that key.
  // Testnet: the funder sends free test NEAR once. Mainnet: the user funds it.
  app.post('/v1/pay/register', async (c) => {
    const userId = c.get('userId');
    if (!isApp(c)) return c.json({ error: 'set up payments in the Pip app' }, 403);
    const n = networks.get(userId);
    const off = mainnetOff(c, n);
    if (off) return off;
    const pk = parsePublicKey((await json(c, Register)).publicKey);
    if (!pk) return c.json({ error: 'publicKey must be an Ed25519 key: 64 hex chars or ed25519:<base58>' }, 400);
    const accountId = implicitAccountId(pk);
    const publicKey = nearPublicKey(pk);
    let a = store.account(userId, n);
    if (a && a.public_key !== publicKey) return c.json({ error: 'a different key is already registered on this network' }, 409);
    if (!a) {
      const testnet = n === 'testnet';
      if (testnet && store.accountCount(n) >= cfg.maxWallets) return c.json({ error: 'no new wallets right now' }, 503);
      if (!store.claimAccount(userId, n, accountId, publicKey, testnet ? 'funding' : 'ready')) return c.json({ error: 'this key is already registered' }, 409);
      pay.audit(userId, null, `phone_key_registered_${n}`);
      a = store.account(userId, n)!;
    }
    // Testnet funding: one send per claim. A failed send may be retried; at worst a user gets 0.2 extra test NEAR.
    if (a.status === 'failed') store.moveAccount(userId, n, 'failed', 'funding');
    if (n === 'testnet' && store.account(userId, n)!.status === 'funding') {
      const chain = chainFor(n);
      if (!chain.fund) {
        store.moveAccount(userId, n, 'funding', 'failed');
        return c.json({ error: 'test money is not set up on this server', account_id: accountId, network: n }, 503);
      }
      try {
        const tx = await chain.fund(accountId, toUnits(cfg.newWalletNear, 'NEAR'));
        store.moveAccount(userId, n, 'funding', 'ready', tx);
        log('pay_phone_funded', { user_id: userId, ok: true });
      } catch (e) {
        store.moveAccount(userId, n, 'funding', 'failed');
        log('pay_phone_funded', { user_id: userId, ok: false, err: (e as Error).message });
        return c.json({ error: 'could not send test money; try again', account_id: accountId, network: n }, 502);
      }
    }
    a = store.account(userId, n)!;
    return c.json({ account_id: a.account_id, public_key: a.public_key, network: n, status: a.status, fund_tx: a.fund_tx });
  });

  app.get('/v1/pay/wallet', async (c, next) => {
    const userId = c.get('userId');
    if (!phoneMode(userId)) return next();
    const n = networks.get(userId);
    const a = store.account(userId, n);
    if (!a) return c.json({ status: 'unregistered', network: n, signing: 'phone' }, 404);
    const b = await chainFor(n).balances(a.account_id).catch(() => undefined);
    if (!b) return rpcDown(c, n);
    return c.json({
      account_id: a.account_id, public_key: a.public_key, status: a.status, network: n, signing: 'phone',
      balances: { NEAR: fromUnits(b.NEAR, 'NEAR'), USDC: fromUnits(b.USDC, 'USDC') }, caps: settings(n).caps,
    });
  });

  app.post('/v1/pay/parse', async (c, next) => {
    const userId = c.get('userId');
    if (networks.get(userId) !== 'mainnet') return next();
    const { text } = await json(c, ParseBody);
    let r: ParseResult = parsePayment(text, check('mainnet'));
    if (r.valid) {
      const found = await recipientOk('mainnet', r.recipient);
      if (found === undefined) return rpcDown(c, 'mainnet');
      if (!found) r = { valid: false, reason: `${r.recipient} does not exist on mainnet` };
    }
    return c.json({ ...r, source: 'regex', network: 'mainnet' });
  });

  // ---- intents: same exact-field rules, caps and 10-minute life as testnet, with the user's network's rules.
  app.post('/v1/pay/intents', async (c, next) => {
    const userId = c.get('userId');
    if (!phoneMode(userId)) return next();
    const n = networks.get(userId);
    const off = mainnetOff(c, n);
    if (off) return off;
    const r = check(n)(await json(c, Fields));
    if (!r.valid) return c.json({ error: r.reason }, 400);
    const units = toUnits(r.amount, r.token);
    const cap = settings(n).caps[r.token];
    if (units > toUnits(cap.perTx, r.token)) return c.json({ error: `over the ${cap.perTx} ${r.token} limit per payment` }, 400);
    const found = await recipientOk(n, r.recipient);
    if (found === undefined) return rpcDown(c, n);
    if (!found) return c.json({ error: `${r.recipient} does not exist on ${n}` }, 400);
    const at = now();
    const id = randomBytes(16).toString('hex');
    store.addIntent({
      id, user_id: userId, network: n, token: r.token, amount: r.amount, units: units.toString(), recipient: r.recipient,
      new_recipient: store.knownRecipient(userId, n, r.recipient) ? 0 : 1, created_at: at, expires_at: at + cfg.intentTtlMs,
    });
    pay.audit(userId, id, `proposed_${n}`);
    return c.json(view(store.intent(id)!), 201);
  });

  /** The phone intent behind :id, or undefined when :id belongs to the legacy path. */
  const phoneIntent = (c: Context<Env>) => {
    const id = IntentId.safeParse(c.req.param('id'));
    const i = id.success ? store.intent(id.data) : undefined;
    if (i && i.user_id !== c.get('userId')) throw new HttpError(404, 'no such payment');
    return i && expireIfDue(i);
  };
  const owned = (c: Context<Env>) => {
    const i = phoneIntent(c);
    if (!i) throw new HttpError(404, 'no such payment');
    return i;
  };
  const expireIfDue = (i: PhoneIntent) => {
    if (i.expires_at <= now()) {
      for (const from of ['pending', 'built'] as const) if (store.move(i.id, from, 'expired', { decidedAt: now() })) pay.audit(i.user_id, i.id, 'expired');
    }
    return store.intent(i.id)!;
  };

  app.get('/v1/pay/intents/:id', (c, next) => {
    const i = phoneIntent(c);
    return i ? c.json(view(i)) : next();
  });
  app.post('/v1/pay/intents/:id/reject', (c, next) => {
    const i = phoneIntent(c);
    if (!i) return next();
    for (const from of ['pending', 'built'] as const) if (store.move(i.id, from, 'rejected', { decidedAt: now() })) pay.audit(i.user_id, i.id, 'rejected');
    const after = store.intent(i.id)!;
    if (after.status !== 'rejected') return c.json({ error: `this payment is ${after.status}`, ...view(after) }, 409);
    return c.json(view(after));
  });
  app.post('/v1/pay/intents/:id/approve', (c, next) => {
    const i = phoneIntent(c);
    return i ? c.json({ error: 'sign this payment in the Pip app', ...view(i) }, 409) : next();
  });

  // ---- unsigned: build the exact transaction once. A second call returns the same bytes; nothing is rebuilt.
  app.post('/v1/pay/intents/:id/unsigned', async (c) => {
    const userId = c.get('userId');
    const fields = await json(c, Fields);
    let i = owned(c);
    const off = mainnetOff(c, i.network);
    if (off) return off;
    if (i.status === 'built') return c.json(unsignedView(i));
    if (i.status !== 'pending') {
      if (i.status === 'expired') return c.json({ error: 'this payment expired; start again', ...view(i) }, 410);
      return c.json({ error: `this payment is ${i.status}`, ...view(i) }, 409);
    }
    if (fields.amount !== i.amount || fields.token !== i.token || fields.recipient !== i.recipient) return c.json({ error: 'the details do not match this payment' }, 409);
    if (i.new_recipient && !isApp(c)) return c.json({ error: 'approve a new recipient in the Pip app' }, 403);
    // A re-quote changes the amount and deposit account: the answer carries the fresh card and requoted: true, so the app re-shows it.
    let requoted = false;
    if (deps.xchain?.describe(i.id)) {
      const r = await deps.xchain.refresh(i);
      if ('error' in r) return c.json({ error: r.error, ...view(i) }, r.status);
      requoted = r.requoted;
      i = store.intent(i.id)!;
    }
    const a = store.account(userId, i.network);
    if (a?.status !== 'ready') return c.json({ error: 'register your key in the Pip app first' }, 409);
    const n = i.network;
    const chain = chainFor(n);
    const units = BigInt(i.units);
    let built;
    try {
      const chainNonce = await chain.accessKeyNonce(a.account_id, a.public_key);
      if (chainNonce === null) return c.json({ error: `fund your account first: ${a.account_id}`, account_id: a.account_id, network: n }, 409);
      const last = store.lastNonce(n, a.public_key);
      const nonce = (chainNonce > last ? chainNonce : last) + 1n;
      const blockHash = await chain.recentBlockHash();
      const pk = parsePublicKey(a.public_key)!;
      const x = await deps.xchain?.build(i, { signerId: a.account_id, publicKey: pk, nonce, blockHash });
      if (x) built = { nonce, ...x };
      else {
        if (i.token === 'USDT') throw new Error('USDT is only sent cross-chain');
        const storageDeposit = i.token === 'USDC' && !(await chain.storageRegistered(i.recipient)) ? await chain.storageMin() : null;
        built = { nonce, ...buildTransfer({ signerId: a.account_id, publicKey: pk, nonce, blockHash, token: i.token, recipient: i.recipient, units, usdcContract: settings(n).usdcContract, storageDeposit }) };
      }
    } catch (e) {
      log('pay_rpc_failed', { network: n, err: (e as Error).message });
      return rpcDown(c, n);
    }
    const claim = db.tx(() => {
      const cap = settings(n).caps[i.token];
      if (units > toUnits(cap.perTx, i.token)) return `over the ${cap.perTx} ${i.token} limit per payment`;
      if (store.spentSince(userId, n, i.token, now() - DAY) + units > toUnits(cap.daily, i.token)) return `over the ${cap.daily} ${i.token} daily limit`;
      return store.move(i.id, 'pending', 'built', {
        decidedAt: now(), txB64: Buffer.from(built.bytes).toString('base64'), txHash: baseEncode(built.hash), nonce: built.nonce.toString(), publicKey: a.public_key,
      }) ? 'ok' : 'lost';
    });
    i = store.intent(i.id)!;
    if (claim === 'lost') return i.status === 'built' ? c.json(unsignedView(i)) : c.json({ error: `this payment is ${i.status}`, ...view(i) }, 409);
    if (claim !== 'ok') {
      pay.audit(userId, i.id, 'cap_blocked');
      return c.json({ error: claim }, 403);
    }
    pay.audit(userId, i.id, 'built');
    return c.json(unsignedView(i, requoted));
  });

  // ---- submit: the phone's signature over sha256(tx). Checked against the registered key and the exact stored bytes, then one broadcast.
  app.post('/v1/pay/intents/:id/submit', async (c) => {
    const userId = c.get('userId');
    const { signature } = await json(c, Submit);
    let i = owned(c);
    const off = mainnetOff(c, i.network);
    if (off) return off;
    if (['sending', 'sent', 'failed', 'outcome_unknown'].includes(i.status)) return c.json(view(i), i.status === 'sent' ? 200 : 202);
    if (i.status !== 'built') {
      if (i.status === 'expired') return c.json({ error: 'this payment expired; start again', ...view(i) }, 410);
      return c.json({ error: `this payment is ${i.status}`, ...view(i) }, 409);
    }
    const sig = parseSignature(signature);
    const bytes = Buffer.from(i.tx_b64!, 'base64');
    const pk = parsePublicKey(i.public_key!)!;
    if (!sig || !verifySignature(pk, sha256(bytes), sig)) {
      pay.audit(userId, i.id, 'bad_signature');
      return c.json({ error: 'the signature does not match this payment' }, 400);
    }
    if (!store.move(i.id, 'built', 'sending')) return c.json(view(store.intent(i.id)!), 202);
    pay.audit(userId, i.id, 'signed');
    let outcome: 'sent' | 'failed' | 'outcome_unknown';
    try {
      outcome = (await chainFor(i.network).broadcast(signedBytes(bytes, sig))) === 'ok' ? 'sent' : 'failed';
    } catch (e) {
      // It may have landed. Never rebuilt or resent; the hash lets anyone check.
      outcome = 'outcome_unknown';
      log('pay_send_unknown', { user_id: userId, intent_id: i.id, err: (e as Error).message });
    }
    store.move(i.id, 'sending', outcome);
    if (outcome === 'sent') store.addRecipient(userId, i.network, i.recipient);
    pay.audit(userId, i.id, outcome);
    log('pay_send', { user_id: userId, intent_id: i.id, network: i.network, outcome });
    i = store.intent(i.id)!;
    return c.json(view(i), outcome === 'sent' ? 200 : outcome === 'failed' ? 502 : 202);
  });

  app.get('/v1/pay/history', (c, next) => {
    const userId = c.get('userId');
    if (!phoneMode(userId)) return next();
    return c.json({ payments: store.history(userId, networks.get(userId), 50).map((i) => view(expireIfDue(i))) });
  });

  function unsignedView(i: PhoneIntent, requoted = false) {
    const bytes = Buffer.from(i.tx_b64!, 'base64');
    return {
      ...view(i), requoted, signer_id: store.account(i.user_id, i.network)?.account_id ?? null, public_key: i.public_key, nonce: i.nonce,
      tx_base64: i.tx_b64, sign_hash_hex: Buffer.from(sha256(bytes)).toString('hex'), sign: 'Ed25519 over the 32 bytes of sign_hash_hex; send base64 (64 bytes) to /submit',
    };
  }
}

