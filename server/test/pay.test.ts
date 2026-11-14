import { test } from 'node:test';
import assert from 'node:assert/strict';
import { setup } from './helpers.ts';
import { parsePayment, toUnits, fromUnits } from '../src/pay/parse.ts';
import { assertTestnet, payConfig } from '../src/pay/config.ts';
import type { Chain } from '../src/pay/chain.ts';

// ---- parse: fixed patterns, no network
const ok: [string, string, 'NEAR' | 'USDC', string][] = [
  ['send 5 USDC to ana.testnet', '5', 'USDC', 'ana.testnet'],
  ['Send 5 usdc to ana.testnet', '5', 'USDC', 'ana.testnet'],
  ['send 0.01 NEAR to bob.testnet', '0.01', 'NEAR', 'bob.testnet'],
  ['pay ana.testnet 5 USDC', '5', 'USDC', 'ana.testnet'],
  ['transfer 2.50 usdc to shop-1.testnet', '2.5', 'USDC', 'shop-1.testnet'],
  ['give 1 near to a_b.testnet', '1', 'NEAR', 'a_b.testnet'],
  ['hey can you send 5 USDC to ana.testnet thanks', '5', 'USDC', 'ana.testnet'],
  ['send 5 USDC to ana.testnet.', '5', 'USDC', 'ana.testnet'],
  ['send 5 USDC to @ana.testnet', '5', 'USDC', 'ana.testnet'],
  ['send 5usdc to ana.testnet', '5', 'USDC', 'ana.testnet'],
  ['send 007 NEAR to ana.testnet', '7', 'NEAR', 'ana.testnet'],
  ['please pay sub.ana.testnet 0.5 near!', '0.5', 'NEAR', 'sub.ana.testnet'],
  [`send 1 NEAR to ${'a'.repeat(64)}`, '1', 'NEAR', 'a'.repeat(64)],
  ['send 1.000001 USDC to ana.testnet', '1.000001', 'USDC', 'ana.testnet'],
];
for (const [text, amount, token, recipient] of ok) {
  test(`parse ok: ${text.slice(0, 50)}`, () => {
    assert.deepEqual(parsePayment(text), { valid: true, amount, token, recipient });
  });
}
const bad: [string, RegExp][] = [
  ['send 5 USDC to ana', /full account id/],
  ['send 5 USDC to ana.near', /mainnet/],
  ['send 5k USDC to ana.testnet', /plain number/],
  ['send $5 USDC to ana.testnet', /plain number/],
  ['send 5-10 USDC to ana.testnet', /plain number/],
  ['send -5 USDC to ana.testnet', /plain number/],
  ['send 0 NEAR to ana.testnet', /more than zero/],
  ['send 1.0000001 USDC to ana.testnet', /at most 6 decimals/],
  ['send 5 USDC to Ana.testnet', /lower case/],
  ['send 5 USDC to ana..testnet', /not a NEAR account id/],
  ['send 5 USDC to ana.example', /only \.testnet/],
  ['send 5 ETH to ana.testnet', /no payment found/],
  ['send five USDC to ana.testnet', /plain number/],
  ['lunch at 5?', /no payment found/],
  ['send 1 NEAR to a.testnet and send 2 NEAR to b.testnet', /more than one/],
  ['send 5 USDC', /no payment found/],
];
for (const [text, reason] of bad) {
  test(`parse refuses: ${text.slice(0, 50)}`, () => {
    const r = parsePayment(text);
    assert.equal(r.valid, false);
    assert.match((r as { reason: string }).reason, reason);
  });
}

test('units: exact decimal conversion both ways', () => {
  assert.equal(toUnits('0.01', 'NEAR'), 10_000_000_000_000_000_000_000n);
  assert.equal(toUnits('5', 'USDC'), 5_000_000n);
  assert.equal(fromUnits(1_500_000n, 'USDC'), '1.5');
  assert.equal(fromUnits(toUnits('0.000001', 'NEAR'), 'NEAR'), '0.000001');
});

test('config: testnet only', () => {
  assert.throws(() => assertTestnet({ ...payConfig, rpcUrl: 'https://rpc.mainnet.near.org' }), /testnet RPC/);
  assert.throws(() => assertTestnet({ ...payConfig, funderAccountId: 'pip.near' }), /\.testnet/);
  assert.doesNotThrow(() => assertTestnet({ ...payConfig, funderAccountId: 'pip.testnet' }));
});

// ---- routes, with a fake chain
function fakeChain(o: { broadcast?: 'ok' | 'failed' | Error; prepare?: Error; down?: boolean } = {}) {
  const accounts = new Set(['ana.testnet', 'bob.testnet']);
  const sends: { from: string; secretKey: string; token: string; recipient: string; units: bigint }[] = [];
  const created: string[] = [];
  let n = 0;
  const chain: Chain = {
    async accountExists(id) {
      if (o.down) throw new Error('rpc down');
      return accounts.has(id) || created.includes(id);
    },
    async balances() { return { NEAR: toUnits('0.2', 'NEAR'), USDC: 0n }; },
    newKey() { n++; return { publicKey: `ed25519:pub${n}`, secretKey: `ed25519:secret${n}` }; },
    async createAccount(id) { created.push(id); return `create${created.length}`; },
    async prepareSend(from, token, recipient, units) {
      if (o.prepare) throw o.prepare;
      sends.push({ from: from.accountId, secretKey: from.secretKey, token, recipient, units });
      return {
        hash: `hash${sends.length}`,
        async broadcast() {
          if (o.broadcast instanceof Error) throw o.broadcast;
          return o.broadcast ?? 'ok';
        },
      };
    },
  };
  return { chain, sends, created };
}

function paySetup(o: Parameters<typeof fakeChain>[0] = {}, now?: () => number) {
  const fake = fakeChain(o);
  const config = { ...payConfig, funderAccountId: 'pipfund.testnet', funderSecretKey: 'ed25519:funder', legacyCustody: true };
  const s = setup({ pay: { chain: fake.chain, config }, now });
  const user = s.device();
  return { ...s, ...fake, user };
}

async function ready(s: ReturnType<typeof paySetup>) {
  assert.equal((await s.call(s.user.token, 'GET', '/v1/pay/wallet')).status, 200);
  const approver = ((await (await s.call(s.user.token, 'POST', '/v1/pay/approver')).json()) as { approver_key: string }).approver_key;
  return approver;
}
const propose = async (s: ReturnType<typeof paySetup>, fields = { amount: '0.01', token: 'NEAR', recipient: 'bob.testnet' }) =>
  (await s.call(s.user.token, 'POST', '/v1/pay/intents', fields)).json() as Promise<{ id: string; deep_link: string; status: string }>;
const approve = (s: ReturnType<typeof paySetup>, id: string, key: string | null, fields = { amount: '0.01', token: 'NEAR', recipient: 'bob.testnet' }) =>
  s.call(s.user.token, 'POST', `/v1/pay/intents/${id}/approve`, fields, key ? { 'X-Pay-Approver': key } : {});

test('pay: parse route checks the recipient exists on testnet', async () => {
  const s = paySetup();
  const good = await (await s.call(s.user.token, 'POST', '/v1/pay/parse', { text: 'send 5 USDC to ana.testnet' })).json();
  assert.deepEqual(good, { valid: true, amount: '5', token: 'USDC', recipient: 'ana.testnet', source: 'regex', network: 'testnet' });
  const missing = (await (await s.call(s.user.token, 'POST', '/v1/pay/parse', { text: 'send 5 USDC to nobody.testnet' })).json()) as { valid: boolean; reason: string };
  assert.equal(missing.valid, false);
  assert.match(missing.reason, /does not exist/);
  assert.equal((await s.call(null, 'POST', '/v1/pay/parse', { text: 'send 5 USDC to ana.testnet' })).status, 401);
});

test('pay: wallet is created once per user and its key is stored encrypted', async () => {
  const s = paySetup();
  const a = (await (await s.call(s.user.token, 'GET', '/v1/pay/wallet')).json()) as { account_id: string; balances: { NEAR: string } };
  const b = (await (await s.call(s.user.token, 'GET', '/v1/pay/wallet')).json()) as { account_id: string };
  assert.equal(a.account_id, b.account_id);
  assert.match(a.account_id, /^pip-[0-9a-f]{12}\.pipfund\.testnet$/);
  assert.equal(a.balances.NEAR, '0.2');
  assert.deepEqual(s.created, [a.account_id]);
  const row = s.db.raw.prepare('SELECT key_enc FROM pay_wallets').get() as { key_enc: string };
  assert.ok(!row.key_enc.includes('secret'));
  assert.equal(s.cipher.decrypt(s.user.userId, row.key_enc), 'ed25519:secret1');
});

test('pay: propose, then approve sends once with the exact fields', async () => {
  const s = paySetup();
  const key = await ready(s);
  const intent = await propose(s);
  assert.equal(intent.status, 'pending');
  assert.equal(intent.deep_link, `pip://approve/${intent.id}`);
  const res = await approve(s, intent.id, key);
  assert.equal(res.status, 200);
  const out = (await res.json()) as { status: string; tx_hash: string; explorer_url: string };
  assert.equal(out.status, 'sent');
  assert.equal(out.explorer_url, `https://testnet.nearblocks.io/txns/${out.tx_hash}`);
  assert.equal(s.sends.length, 1);
  assert.equal(s.sends[0].units, toUnits('0.01', 'NEAR'));
  assert.equal(s.sends[0].secretKey, 'ed25519:secret1');
  const hist = (await (await s.call(s.user.token, 'GET', '/v1/pay/history')).json()) as { payments: { status: string }[] };
  assert.deepEqual(hist.payments.map((p) => p.status), ['sent']);
});

test('pay: double approve, in parallel or later, never sends twice', async () => {
  const s = paySetup();
  const key = await ready(s);
  const intent = await propose(s);
  const [a, b] = await Promise.all([approve(s, intent.id, key), approve(s, intent.id, key)]);
  const later = await approve(s, intent.id, key);
  assert.equal(s.sends.length, 1);
  for (const r of [a, b, later]) assert.ok(r.status < 300);
  assert.equal(((await later.json()) as { status: string }).status, 'sent');
});

test('pay: approve without the app approver key is refused (keyboard token alone)', async () => {
  const s = paySetup();
  await ready(s);
  const intent = await propose(s);
  assert.equal((await approve(s, intent.id, null)).status, 403);
  assert.equal((await approve(s, intent.id, 'pap_' + 'x'.repeat(43))).status, 403);
  assert.equal(s.sends.length, 0);
  // A second approver cannot be set up while the first one's session is alive.
  assert.equal((await s.call(s.user.token, 'POST', '/v1/pay/approver')).status, 409);
});

test('pay: another user cannot see or approve the intent', async () => {
  const s = paySetup();
  await ready(s);
  const intent = await propose(s);
  const other = s.device();
  const otherKey = ((await (await s.call(other.token, 'POST', '/v1/pay/approver')).json()) as { approver_key: string }).approver_key;
  const r = await s.call(other.token, 'POST', `/v1/pay/intents/${intent.id}/approve`, { amount: '0.01', token: 'NEAR', recipient: 'bob.testnet' }, { 'X-Pay-Approver': otherKey });
  assert.equal(r.status, 404);
  assert.equal((await s.call(other.token, 'GET', `/v1/pay/intents/${intent.id}`)).status, 404);
  assert.equal(s.sends.length, 0);
});

test('pay: approve with changed fields is refused', async () => {
  const s = paySetup();
  const key = await ready(s);
  const intent = await propose(s);
  assert.equal((await approve(s, intent.id, key, { amount: '0.02', token: 'NEAR', recipient: 'bob.testnet' })).status, 409);
  assert.equal((await approve(s, intent.id, key, { amount: '0.01', token: 'NEAR', recipient: 'ana.testnet' })).status, 409);
  assert.equal(s.sends.length, 0);
});

test('pay: intent expires after 10 minutes', async () => {
  let t = Date.now();
  const s = paySetup({}, () => t);
  const key = await ready(s);
  const intent = await propose(s);
  t += 10 * 60_000;
  const r = await approve(s, intent.id, key);
  assert.equal(r.status, 410);
  assert.equal(((await r.json()) as { status: string }).status, 'expired');
  assert.equal(s.sends.length, 0);
});

test('pay: per-payment cap at proposal, daily cap at approval', async () => {
  const s = paySetup();
  const key = await ready(s);
  const big = await s.call(s.user.token, 'POST', '/v1/pay/intents', { amount: '1.01', token: 'NEAR', recipient: 'bob.testnet' });
  assert.equal(big.status, 400);
  const f = { amount: '1', token: 'NEAR', recipient: 'bob.testnet' };
  const ids = [(await propose(s, f)).id, (await propose(s, f)).id, (await propose(s, f)).id];
  assert.equal((await approve(s, ids[0], key, f)).status, 200);
  assert.equal((await approve(s, ids[1], key, f)).status, 200);
  const third = await approve(s, ids[2], key, f);
  assert.equal(third.status, 403);
  assert.match(((await third.json()) as { error: string }).error, /daily limit/);
  assert.equal(s.sends.length, 2);
});

test('pay: reject ends the intent; it cannot be approved after', async () => {
  const s = paySetup();
  const key = await ready(s);
  const intent = await propose(s);
  assert.equal((await s.call(s.user.token, 'POST', `/v1/pay/intents/${intent.id}/reject`)).status, 200);
  assert.equal((await approve(s, intent.id, key)).status, 409);
  assert.equal(s.sends.length, 0);
});

test('pay: an unknown broadcast outcome is never retried', async () => {
  const s = paySetup({ broadcast: new Error('timeout') });
  const key = await ready(s);
  const intent = await propose(s);
  const r = await approve(s, intent.id, key);
  assert.equal(r.status, 202);
  assert.equal(((await r.json()) as { status: string; tx_hash: string }).status, 'outcome_unknown');
  await approve(s, intent.id, key);
  assert.equal(s.sends.length, 1);
});

test('pay: a failure before broadcast is marked failed, nothing sent', async () => {
  const s = paySetup({ prepare: new Error('nonce') });
  const key = await ready(s);
  const intent = await propose(s);
  const r = await approve(s, intent.id, key);
  assert.equal(r.status, 502);
  assert.equal(((await r.json()) as { status: string }).status, 'failed');
});

test('pay: no funder configured answers 503; RPC down answers 502', async () => {
  const s = setup({ pay: { chain: fakeChain().chain, config: { ...payConfig, funderAccountId: '', funderSecretKey: '', legacyCustody: true } } });
  const u = s.device();
  assert.equal((await s.call(u.token, 'GET', '/v1/pay/wallet')).status, 503);
  const d = paySetup({ down: true });
  assert.equal((await d.call(d.user.token, 'POST', '/v1/pay/parse', { text: 'send 1 NEAR to ana.testnet' })).status, 502);
});

test('pay: a deleted user takes their wallet and intents with them', async () => {
  const s = paySetup();
  await ready(s);
  await propose(s);
  s.db.deleteUser(s.user.userId);
  for (const t of ['pay_wallets', 'pay_intents', 'pay_approvers', 'pay_audit']) {
    assert.equal((s.db.raw.prepare(`SELECT COUNT(*) AS n FROM ${t}`).get() as { n: number }).n, 0, t);
  }
});

// ---- keyboard key: capped, known recipients only, set only with the approver key
const kbFields = { amount: '5', token: 'USDC', recipient: 'ana.testnet' };
const kbApprove = (s: ReturnType<typeof paySetup>, id: string, key: string, fields = kbFields) =>
  s.call(s.user.token, 'POST', `/v1/pay/intents/${id}/keyboard-approve`, fields, { 'X-Pay-Keyboard': key });
async function keyboardKey(s: ReturnType<typeof paySetup>, approver: string, limits = { usdc_daily: '20', near_daily: '1' }) {
  const res = await s.call(s.user.token, 'POST', '/v1/pay/keyboard', limits, { 'X-Pay-Approver': approver });
  assert.equal(res.status, 200);
  return ((await res.json()) as { keyboard_key: string }).keyboard_key;
}

test('pay keyboard: the key is made only with the approver key, and cannot make itself', async () => {
  const s = paySetup();
  const approver = await ready(s);
  assert.equal((await s.call(s.user.token, 'POST', '/v1/pay/keyboard', { usdc_daily: '20', near_daily: '1' })).status, 403);
  const kb = await keyboardKey(s, approver);
  assert.match(kb, /^pkb_/);
  const self = await s.call(s.user.token, 'POST', '/v1/pay/keyboard', { usdc_daily: '25', near_daily: '2' }, { 'X-Pay-Approver': kb });
  assert.equal(self.status, 403);
  const row = s.db.raw.prepare('SELECT key_hash FROM pay_keyboard').get() as { key_hash: string };
  assert.ok(!row.key_hash.includes(kb));
});

test('pay keyboard: a new recipient always needs the app', async () => {
  const s = paySetup();
  const kb = await keyboardKey(s, await ready(s));
  const i = (await (await s.call(s.user.token, 'POST', '/v1/pay/intents', kbFields)).json()) as { id: string; keyboard: { ok: boolean; reason: string } };
  assert.deepEqual([i.keyboard.ok, i.keyboard.reason], [false, 'new_recipient']);
  const res = await kbApprove(s, i.id, kb);
  assert.equal(res.status, 403);
  assert.equal(((await res.json()) as { needs_app: boolean }).needs_app, true);
  assert.equal(s.sends.length, 0);
});

test('pay keyboard: a paid-before recipient within the limit sends; over the limit needs the app', async () => {
  const s = paySetup();
  const approver = await ready(s);
  const kb = await keyboardKey(s, approver, { usdc_daily: '8', near_daily: '1' });
  const first = (await (await s.call(s.user.token, 'POST', '/v1/pay/intents', kbFields)).json()) as { id: string };
  assert.equal((await approve(s, first.id, approver, kbFields)).status, 200);

  const second = (await (await s.call(s.user.token, 'POST', '/v1/pay/intents', kbFields)).json()) as { id: string; keyboard: { ok: boolean; left: string; paid_before: number } };
  assert.deepEqual(second.keyboard, { ok: true, left: '8', paid_before: 1 });
  const res = await kbApprove(s, second.id, kb);
  assert.equal(res.status, 200);
  assert.equal(((await res.json()) as { status: string }).status, 'sent');
  assert.equal(s.sends.length, 2);

  const third = (await (await s.call(s.user.token, 'POST', '/v1/pay/intents', kbFields)).json()) as { id: string; keyboard: { ok: boolean; reason: string; left: string } };
  assert.deepEqual([third.keyboard.ok, third.keyboard.reason, third.keyboard.left], [false, 'over_limit', '3']);
  assert.equal((await kbApprove(s, third.id, kb)).status, 403);
  assert.equal(s.sends.length, 2);
  // The app can still approve it.
  assert.equal((await approve(s, third.id, approver, kbFields)).status, 200);
});

test('pay keyboard: the keyboard key cannot use the app approve route, and a wrong key is refused', async () => {
  const s = paySetup();
  const approver = await ready(s);
  const kb = await keyboardKey(s, approver);
  const i = (await (await s.call(s.user.token, 'POST', '/v1/pay/intents', kbFields)).json()) as { id: string };
  assert.equal((await s.call(s.user.token, 'POST', `/v1/pay/intents/${i.id}/approve`, kbFields, { 'X-Pay-Approver': kb })).status, 403);
  assert.equal((await kbApprove(s, i.id, 'pkb_' + 'x'.repeat(43))).status, 403);
  assert.equal((await kbApprove(s, i.id, approver)).status, 403);
  assert.equal(s.sends.length, 0);
});

test('pay keyboard: the keyboard limit never exceeds the server daily cap', async () => {
  const s = paySetup();
  const res = await s.call(s.user.token, 'POST', '/v1/pay/keyboard', { usdc_daily: '500', near_daily: '50' }, { 'X-Pay-Approver': await ready(s) });
  assert.deepEqual(((await res.json()) as { limits: unknown }).limits, { USDC: payConfig.caps.USDC.daily, NEAR: payConfig.caps.NEAR.daily });
});
