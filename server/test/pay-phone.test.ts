import { test } from 'node:test';
import assert from 'node:assert/strict';
import { generateKeyPairSync, sign, type KeyObject } from 'node:crypto';
import { SignedTransaction, Transaction, baseEncode } from 'near-api-js';
import { setup } from './helpers.ts';
import { payConfig } from '../src/pay/config.ts';
import { mainnetConfig } from '../src/pay/network.ts';
import { toUnits } from '../src/pay/parse.ts';
import type { PhoneChain } from '../src/pay/phone/chain.ts';
import { approvalMessage, buildTransfer, sha256 } from '../src/pay/phone/tx.ts';

const BLOCK = 'GJ8ThW5tGmvBbGr8Kto6Ahtv1mhK5cXhkRMdNsJxbVkK';

function phoneKey() {
  const { publicKey, privateKey } = generateKeyPairSync('ed25519');
  const raw = Buffer.from(publicKey.export({ format: 'jwk' }).x!, 'base64url');
  return { hex: raw.toString('hex'), raw: new Uint8Array(raw), privateKey };
}
/** What the phone does: Ed25519 over the 32 hash bytes, sent as base64. */
const signHash = (hashHex: string, key: KeyObject) => sign(null, Buffer.from(hashHex, 'hex'), key).toString('base64');

function fakeChain(o: { broadcast?: 'ok' | 'failed' | Error; unfunded?: boolean } = {}) {
  const exists = new Set(['ana.testnet', 'bob.testnet', 'ana.near', 'bob.near']);
  const registered = new Set(['bob.testnet', 'bob.near']);
  const sent: Uint8Array[] = [];
  const funded: { accountId: string; units: bigint }[] = [];
  let nonce = 1000n;
  const chain: PhoneChain = {
    async accountExists(id) { return exists.has(id); },
    async accessKeyNonce() { return o.unfunded ? null : nonce; },
    async recentBlockHash() { return BLOCK; },
    async storageRegistered(id) { return registered.has(id); },
    async storageMin() { return 1_250_000_000_000_000_000_000n; },
    async balances() { return { NEAR: toUnits('1', 'NEAR'), USDC: 0n }; },
    async broadcast(b) {
      sent.push(b);
      if (o.broadcast instanceof Error) throw o.broadcast;
      return o.broadcast ?? 'ok';
    },
    async fund(accountId, units) { funded.push({ accountId, units }); return 'FundTxHash'; },
  };
  return { chain, sent, funded, bumpNonce: (n: bigint) => { nonce = n; } };
}

function world(o: { mainnet?: boolean; chain?: Parameters<typeof fakeChain>[0]; now?: () => number } = {}) {
  const fake = fakeChain(o.chain);
  const config = { ...payConfig, funderAccountId: 'pipfund.testnet', funderSecretKey: 'ed25519:funder' };
  const mainnet = { ...mainnetConfig, enabled: o.mainnet ?? false };
  const s = setup({ pay: { config, phone: { chains: { testnet: fake.chain, mainnet: fake.chain }, mainnet } }, now: o.now });
  const { token } = s.device();
  const key = phoneKey();
  let approver = '';
  const call = (method: string, path: string, body?: unknown, app = false) => s.call(token, method, path, body, app ? { 'x-pay-approver': approver } : {});
  const start = async (network: 'testnet' | 'mainnet' = 'testnet') => {
    approver = (await (await call('POST', '/v1/pay/approver')).json()).approver_key;
    if (network === 'mainnet') assert.equal((await call('PUT', '/v1/pay/network', { network }, true)).status, 200);
    const r = await call('POST', '/v1/pay/register', { publicKey: key.hex }, true);
    assert.equal(r.status, 200);
    return r.json();
  };
  const intent = async (fields: { amount: string; token: string; recipient: string }) => {
    const r = await call('POST', '/v1/pay/intents', fields);
    assert.equal(r.status, 201, await r.clone().text());
    return { ...(await r.json()), fields };
  };
  const unsigned = (i: { id: string; fields: object }, app = true) => call('POST', `/v1/pay/intents/${i.id}/unsigned`, i.fields, app);
  const submit = (id: string, signature: string) => call('POST', `/v1/pay/intents/${id}/submit`, { signature });
  return { s, fake, key, token, call, start, intent, unsigned, submit };
}

// ---- the pure builder
test('phone tx: the same plan gives the same bytes; fields round-trip', () => {
  const key = phoneKey();
  const plan = { signerId: key.hex, publicKey: key.raw, nonce: 1001n, blockHash: BLOCK, token: 'NEAR' as const, recipient: 'ana.near', units: toUnits('0.5', 'NEAR'), usdcContract: mainnetConfig.usdcContract, storageDeposit: null };
  const a = buildTransfer(plan), b = buildTransfer(plan);
  assert.deepEqual(a.bytes, b.bytes);
  assert.deepEqual(a.hash, sha256(a.bytes));
  const tx = Transaction.decode(a.bytes);
  assert.equal(tx.signerId, key.hex);
  assert.equal(tx.receiverId, 'ana.near');
  assert.equal(tx.nonce, 1001n);
  assert.equal(baseEncode(new Uint8Array(tx.blockHash)), BLOCK);
  assert.equal(tx.actions[0].transfer?.deposit, toUnits('0.5', 'NEAR'));
  assert.notDeepEqual(buildTransfer({ ...plan, nonce: 1002n }).bytes, a.bytes);
});

// ---- the flow on testnet
test('phone testnet: register funds the implicit account once; full sign-and-submit sends once', async () => {
  const w = world();
  const reg = await w.start();
  assert.equal(reg.account_id, w.key.hex);
  assert.equal(reg.status, 'ready');
  assert.deepEqual(w.fake.funded, [{ accountId: w.key.hex, units: toUnits(payConfig.newWalletNear, 'NEAR') }]);
  assert.equal((await w.call('POST', '/v1/pay/register', { publicKey: w.key.hex }, true)).status, 200);
  assert.equal(w.fake.funded.length, 1, 'registering again never funds again');

  const i = await w.intent({ amount: '0.1', token: 'NEAR', recipient: 'ana.testnet' });
  assert.equal(i.new_recipient, true);
  assert.equal(i.signing, 'phone');
  const u = await (await w.unsigned(i)).json();
  assert.equal(u.status, 'built');
  assert.equal(u.signer_id, w.key.hex);
  assert.equal(u.nonce, '1001');
  assert.equal(u.sign_hash_hex, Buffer.from(sha256(Buffer.from(u.tx_base64, 'base64'))).toString('hex'));
  assert.equal(u.tx_hash, baseEncode(Buffer.from(u.sign_hash_hex, 'hex')));

  // Asking again gives the same bytes even when the chain moved on.
  w.fake.bumpNonce(5000n);
  const again = await (await w.unsigned(i)).json();
  assert.equal(again.tx_base64, u.tx_base64);

  const r = await w.submit(i.id, signHash(u.sign_hash_hex, w.key.privateKey));
  assert.equal(r.status, 200);
  const done = await r.json();
  assert.equal(done.status, 'sent');
  assert.equal(done.explorer_url, `${payConfig.explorerTx}${u.tx_hash}`);
  assert.equal(w.fake.sent.length, 1);
  const stx = SignedTransaction.decode(w.fake.sent[0]);
  assert.deepEqual(stx.transaction.encode(), new Uint8Array(Buffer.from(u.tx_base64, 'base64')));

  // Replay: the same signature again returns the first result and never broadcasts again.
  const replay = await w.submit(i.id, signHash(u.sign_hash_hex, w.key.privateKey));
  assert.equal((await replay.json()).status, 'sent');
  assert.equal(w.fake.sent.length, 1);

  // The recipient is now known: the next send to them needs no app key; the nonce moves past both chain and last built.
  const j = await w.intent({ amount: '0.1', token: 'NEAR', recipient: 'ana.testnet' });
  assert.equal(j.new_recipient, false);
  const uj = await w.unsigned(j, false);
  assert.equal(uj.status, 200);
  assert.equal((await uj.json()).nonce, '5001');
});

test('phone: a wrong key, a signature over another tx, or junk is refused; the intent stays signable', async () => {
  const w = world();
  await w.start();
  const a = await w.intent({ amount: '0.1', token: 'NEAR', recipient: 'ana.testnet' });
  const b = await w.intent({ amount: '0.2', token: 'NEAR', recipient: 'ana.testnet' });
  const ua = await (await w.unsigned(a)).json();
  const ub = await (await w.unsigned(b)).json();
  assert.notEqual(ua.nonce, ub.nonce, 'two built txs never share a nonce');

  const other = phoneKey();
  const wrongKey = await w.submit(a.id, signHash(ua.sign_hash_hex, other.privateKey));
  assert.equal(wrongKey.status, 400);
  const otherTx = await w.submit(a.id, signHash(ub.sign_hash_hex, w.key.privateKey));
  assert.equal(otherTx.status, 400);
  assert.equal((await w.submit(a.id, 'not-a-signature')).status, 400);
  assert.equal(w.fake.sent.length, 0);

  const ok = await w.submit(a.id, signHash(ua.sign_hash_hex, w.key.privateKey));
  assert.equal((await ok.json()).status, 'sent');
});

test('phone: an unknown broadcast outcome is kept and never resent', async () => {
  const w = world({ chain: { broadcast: new Error('timeout') } });
  await w.start();
  const i = await w.intent({ amount: '0.1', token: 'NEAR', recipient: 'ana.testnet' });
  const u = await (await w.unsigned(i)).json();
  const sig = signHash(u.sign_hash_hex, w.key.privateKey);
  const r = await w.submit(i.id, sig);
  assert.equal(r.status, 202);
  assert.equal((await r.json()).status, 'outcome_unknown');
  await w.submit(i.id, sig);
  assert.equal((await (await w.unsigned(i)).json()).status, 'outcome_unknown');
  assert.equal(w.fake.sent.length, 1);
});

test('phone: a new recipient needs the app key; the legacy approve route refuses phone intents', async () => {
  const w = world();
  await w.start();
  const i = await w.intent({ amount: '0.1', token: 'NEAR', recipient: 'ana.testnet' });
  assert.equal((await w.unsigned(i, false)).status, 403);
  assert.equal((await w.call('POST', `/v1/pay/intents/${i.id}/approve`, i.fields, true)).status, 409);
  assert.equal((await w.call('POST', '/v1/pay/register', { publicKey: phoneKey().hex })).status, 403);
  assert.equal((await w.call('PUT', '/v1/pay/network', { network: 'testnet' })).status, 403);
});

test('phone: the keyboard approves a new recipient with a Face ID proof from the phone key over that exact intent', async () => {
  const w = world();
  await w.start();
  const i = await w.intent({ amount: '0.1', token: 'NEAR', recipient: 'ana.testnet' });
  const proof = (msg: Uint8Array, key: KeyObject = w.key.privateKey) => sign(null, sha256(msg), key).toString('base64');
  const intent = { id: i.id, network: 'testnet', ...i.fields };
  const tryWith = (p: string) => w.s.call(w.token, 'POST', `/v1/pay/intents/${i.id}/unsigned`, i.fields, { 'x-pay-proof': p });
  // Refused: another key, another intent id, other fields, a signature over the raw text, junk.
  assert.equal((await tryWith(proof(approvalMessage(intent), phoneKey().privateKey))).status, 403, 'another key');
  assert.equal((await tryWith(proof(approvalMessage({ ...intent, id: 'cd'.repeat(16) })))).status, 403, 'another intent');
  assert.equal((await tryWith(proof(approvalMessage({ ...intent, recipient: 'bob.testnet' })))).status, 403, 'other fields');
  assert.equal((await tryWith(proof(approvalMessage({ ...intent, network: 'mainnet' })))).status, 403, 'another network');
  assert.equal((await tryWith(sign(null, approvalMessage(intent), w.key.privateKey).toString('base64'))).status, 403, 'not hashed');
  assert.equal((await tryWith('junk')).status, 403);
  const ok = await tryWith(proof(approvalMessage(intent)));
  assert.equal(ok.status, 200, await ok.clone().text());
  const u = await ok.json();
  assert.equal((await w.submit(i.id, signHash(u.sign_hash_hex, w.key.privateKey))).status, 200);
  const events = w.s.db.raw.prepare('SELECT event FROM pay_audit WHERE intent_id = ? ORDER BY id').all(i.id).map((r) => (r as { event: string }).event);
  assert.ok(events.includes('bad_keyboard_proof') && events.includes('keyboard_proof'), events.join());
});

test('phone: a keyboard proof does not lift the caps', async () => {
  const w = world();
  await w.start();
  const withProof = async (recipient: string) => {
    const i = await w.intent({ amount: '1', token: 'NEAR', recipient });
    const p = sign(null, sha256(approvalMessage({ id: i.id, network: 'testnet', ...i.fields })), w.key.privateKey).toString('base64');
    return w.s.call(w.token, 'POST', `/v1/pay/intents/${i.id}/unsigned`, i.fields, { 'x-pay-proof': p });
  };
  assert.equal((await withProof('ana.testnet')).status, 200);
  assert.equal((await withProof('bob.testnet')).status, 200);
  const r = await withProof('ana.testnet');
  assert.equal(r.status, 403);
  assert.match((await r.json()).error, /daily limit/);
});

test('phone: the unsigned call needs the exact fields the card showed', async () => {
  const w = world();
  await w.start();
  const i = await w.intent({ amount: '0.1', token: 'NEAR', recipient: 'ana.testnet' });
  assert.equal((await w.unsigned({ ...i, fields: { ...i.fields, amount: '0.2' } })).status, 409);
});

// ---- USDC
test('phone USDC: an unregistered recipient gets storage_deposit first; a registered one only ft_transfer', async () => {
  const w = world();
  await w.start();
  const fresh = await w.intent({ amount: '1', token: 'USDC', recipient: 'ana.testnet' });
  const tx1 = Transaction.decode(Buffer.from((await (await w.unsigned(fresh)).json()).tx_base64, 'base64'));
  assert.equal(tx1.receiverId, payConfig.usdcContract);
  assert.deepEqual(tx1.actions.map((a) => a.functionCall?.methodName), ['storage_deposit', 'ft_transfer']);
  assert.equal(tx1.actions[0].functionCall?.deposit, 1_250_000_000_000_000_000_000n);
  assert.deepEqual(JSON.parse(Buffer.from(tx1.actions[0].functionCall!.args).toString()), { account_id: 'ana.testnet', registration_only: true });
  assert.equal(tx1.actions[1].functionCall?.deposit, 1n);
  assert.deepEqual(JSON.parse(Buffer.from(tx1.actions[1].functionCall!.args).toString()), { receiver_id: 'ana.testnet', amount: '1000000' });

  const reg = await w.intent({ amount: '1', token: 'USDC', recipient: 'bob.testnet' });
  const tx2 = Transaction.decode(Buffer.from((await (await w.unsigned(reg)).json()).tx_base64, 'base64'));
  assert.deepEqual(tx2.actions.map((a) => a.functionCall?.methodName), ['ft_transfer']);
});

// ---- mainnet
test('phone mainnet: off by default; on, it needs no funding, takes .near only, and refuses an unfunded account', async () => {
  const off = world();
  await off.start();
  assert.equal((await off.call('PUT', '/v1/pay/network', { network: 'mainnet' }, true)).status, 503);

  const w = world({ mainnet: true, chain: { unfunded: true } });
  const reg = await w.start('mainnet');
  assert.equal(reg.network, 'mainnet');
  assert.equal(reg.account_id, w.key.hex);
  assert.equal(w.fake.funded.length, 0, 'the server never funds a mainnet account');
  assert.match(await (await w.call('POST', '/v1/pay/intents', { amount: '1', token: 'NEAR', recipient: 'ana.testnet' })).text(), /testnet accounts are not allowed/);
  assert.match(await (await w.call('POST', '/v1/pay/intents', { amount: '1', token: 'NEAR', recipient: 'ana' })).text(), /ana\.near/);
  const p = await (await w.call('POST', '/v1/pay/parse', { text: 'send 1 NEAR to ana.near' })).json();
  assert.equal(p.valid, true);
  const i = await w.intent({ amount: '1', token: 'NEAR', recipient: 'ana.near' });
  assert.equal(i.network, 'mainnet');
  const u = await w.unsigned(i);
  assert.equal(u.status, 409);
  assert.match(await u.text(), /fund your account first/);
});

test('phone mainnet caps: per payment at proposal; daily at build, counting live built txs; expiry frees them', async () => {
  let t = 1_000_000;
  const w = world({ mainnet: true, now: () => t });
  await w.start('mainnet');
  const big = await w.call('POST', '/v1/pay/intents', { amount: '2.5', token: 'NEAR', recipient: 'ana.near' });
  assert.equal(big.status, 400);
  assert.match(await big.text(), /2 NEAR limit per payment/);

  const ids = [];
  for (const amount of ['2', '2', '1']) ids.push(await w.intent({ amount, token: 'NEAR', recipient: 'ana.near' }));
  const over = await w.intent({ amount: '0.5', token: 'NEAR', recipient: 'ana.near' });
  for (const i of ids) assert.equal((await w.unsigned(i)).status, 200);
  const blocked = await w.unsigned(over);
  assert.equal(blocked.status, 403);
  assert.match(await blocked.text(), /5 NEAR daily limit/);

  // Unsigned built txs expire with their intent and stop counting.
  t += payConfig.intentTtlMs + 1;
  const later = await w.intent({ amount: '0.5', token: 'NEAR', recipient: 'ana.near' });
  assert.equal((await w.unsigned(later)).status, 200);
  assert.equal((await w.submit(ids[0].id, 'x'.repeat(86) + '==')).status, 410);
});

test('legacy custody is off by default: the wallet route answers for the phone flow', async () => {
  const s = setup({ pay: { config: { ...payConfig, funderAccountId: 'pipfund.testnet', funderSecretKey: 'ed25519:funder' }, phone: { chains: { testnet: fakeChain().chain } } } });
  const { token } = s.device();
  const r = await s.call(token, 'GET', '/v1/pay/wallet');
  assert.equal(r.status, 404);
  assert.equal((await r.json()).status, 'unregistered');
});
