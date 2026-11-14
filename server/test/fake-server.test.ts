import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { once } from 'node:events';

const script = new URL('../scripts/fake-server.ts', import.meta.url).pathname;

test('fake server: suggest, /_next, writing help and /_log work with the fixed token and no network', async (t) => {
  const child = spawn(process.execPath, [script], { env: { ...process.env, PORT: '0', NODE_ENV: '' }, stdio: ['ignore', 'pipe', 'inherit'] });
  t.after(() => child.kill());
  let out = '';
  child.stdout.setEncoding('utf8');
  while (!/127\.0\.0\.1:(\d+)/.test(out)) out += (await once(child.stdout, 'data'))[0];
  const base = `http://127.0.0.1:${/127\.0\.0\.1:(\d+)/.exec(out)![1]}`;
  const call = async (path: string, body?: unknown, tap = false) => {
    const res = await fetch(base + path, {
      method: body === undefined ? 'GET' : 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: 'Bearer pkd_fake', ...(tap ? { 'X-User-Action': 'tap' } : {}) },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    return { status: res.status, json: (await res.json()) as any };
  };

  assert.equal((await call('/v1/me')).status, 200);
  const plain = await call('/v1/suggest', { text: 'lunch with the team friday' });
  assert.equal(plain.status, 200);
  assert.deepEqual(plain.json.chips, []);

  await call('/_next', { device: { kind: 'event' } });
  const s = await call('/v1/suggest', { text: 'lunch with the team friday' });
  assert.equal(s.json.chips[0].kind, 'event', JSON.stringify(s.json));
  assert.deepEqual(s.json.chips[0].payload, { title: 'Lunch with the team friday' });

  await call('/_next', { write: 'Thanks for coming.' });
  const fixed = await call('/v1/write/fix', { text: 'thnks for comming' }, true);
  assert.deepEqual([fixed.json.text, fixed.json.changed], ['Thanks for coming.', true]);
  assert.equal((await call('/v1/write/fix', { text: 'thnks for comming' }, true)).json.changed, false, '/_next answers once');

  const log = (await call('/_log')).json;
  assert.deepEqual(log.requests[1], { method: 'POST', path: '/v1/suggest', status: 200, body: { text: 'lunch with the team friday' } });
  assert.deepEqual(log.ai.map((c: any) => c.fn), ['deviceAction', 'deviceAction', 'fix', 'fix']);

  await call('/_reset', {});
  assert.equal((await call('/_log')).json.requests.length, 0);
  assert.equal((await call('/v1/suggest', { text: 'hi' })).status, 200);
  assert.deepEqual((await call('/v1/auth/config')).json, { email_enabled: true }, 'UI tests cover the email form');
});

test('fake server: refuses to start in production', () => {
  const r = spawnSync(process.execPath, [script], { env: { ...process.env, PORT: '0', NODE_ENV: 'production' }, encoding: 'utf8', timeout: 10_000 });
  assert.equal(r.status, 1);
  assert.match(r.stderr, /refuses to start/);
});

test('fake server: pay runs the phone-signed flow; the signature is checked and the balance goes down', async (t) => {
  const { generateKeyPairSync, sign } = await import('node:crypto');
  const child = spawn(process.execPath, [script], { env: { ...process.env, PORT: '0', NODE_ENV: '' }, stdio: ['ignore', 'pipe', 'inherit'] });
  t.after(() => child.kill());
  let out = '';
  child.stdout.setEncoding('utf8');
  while (!/127\.0\.0\.1:(\d+)/.test(out)) out += (await once(child.stdout, 'data'))[0];
  const base = `http://127.0.0.1:${/127\.0\.0\.1:(\d+)/.exec(out)![1]}`;
  let approver = '';
  const call = async (method: string, path: string, body?: unknown) => {
    const res = await fetch(base + path, {
      method, body: body === undefined ? undefined : JSON.stringify(body),
      headers: { 'Content-Type': 'application/json', Authorization: 'Bearer pkd_fake', 'X-User-Action': 'tap', ...(approver ? { 'X-Pay-Approver': approver } : {}) },
    });
    return { status: res.status, json: (await res.json()) as any };
  };
  const { publicKey, privateKey } = generateKeyPairSync('ed25519');
  const hex = Buffer.from(publicKey.export({ format: 'jwk' }).x!, 'base64url').toString('hex');
  approver = (await call('POST', '/v1/pay/approver')).json.approver_key;
  assert.equal((await call('GET', '/v1/pay/network')).json.mainnet_enabled, true, 'the mainnet switch shows in shots');
  assert.equal((await call('POST', '/v1/pay/register', { publicKey: hex })).json.account_id, hex);
  const fields = { amount: '5', token: 'USDC', recipient: 'ana.testnet' };
  const i = (await call('POST', '/v1/pay/intents', fields)).json;
  assert.equal(i.new_recipient, true);
  const u = (await call('POST', `/v1/pay/intents/${i.id}/unsigned`, fields)).json;
  const signature = sign(null, Buffer.from(u.sign_hash_hex, 'hex'), privateKey).toString('base64');
  const sent = await call('POST', `/v1/pay/intents/${i.id}/submit`, { signature });
  assert.equal(sent.json.status, 'sent', JSON.stringify(sent.json));
  assert.match(sent.json.explorer_url, /^https:\/\/testnet\.nearblocks\.io\/txns\//);
  assert.equal((await call('GET', '/v1/pay/wallet')).json.balances.USDC, '37.1');
});
