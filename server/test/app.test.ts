import { test } from 'node:test';
import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import { createCipher, randomToken } from '../src/crypto.ts';
import { setup } from './helpers.ts';

test('crypto: round trip, random IV, tamper detection, cross-user swap fails', () => {
  const c = createCipher(randomBytes(32));
  const a = c.encrypt('user-a', 'sam@example.com');
  assert.equal(c.decrypt('user-a', a), 'sam@example.com');
  assert.notEqual(c.encrypt('user-a', 'sam@example.com'), a);
  assert.ok(!a.includes('sam'));
  const raw = Buffer.from(a.split(':')[1], 'base64');
  raw[raw.length - 1] ^= 1;
  assert.throws(() => c.decrypt('user-a', `v1:${raw.toString('base64')}`));
  assert.throws(() => c.decrypt('user-b', a));
});

test('auth: missing or unknown token is rejected', async () => {
  const { call, device } = setup();
  assert.equal((await call(null, 'GET', '/v1/me')).status, 401);
  assert.equal((await call(randomToken('pkd'), 'GET', '/v1/me')).status, 401);
  assert.deepEqual(await (await call(device().token, 'GET', '/v1/me')).json(), { ok: true });
  assert.equal((await call('garbage', 'POST', '/v1/suggest', { text: 'hi' })).status, 401);
  assert.equal((await call(null, 'GET', '/health')).status, 200);
});

test('limits: oversized body rejected', async () => {
  const s = setup();
  const { token } = s.device();
  const r = await s.call(token, 'POST', '/v1/suggest', { text: 'x'.repeat(20_000) });
  assert.equal(r.status, 413);
});
