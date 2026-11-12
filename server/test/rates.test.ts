import { test } from 'node:test';
import assert from 'node:assert/strict';
import { RATES_TTL_MS, RATES_URL } from '../src/rates.ts';
import { setup } from './helpers.ts';

test('rates: no token is 401 and the source is not read', async () => {
  const { call, rateFetches } = setup();
  assert.equal((await call(null, 'GET', '/v1/rates')).status, 401);
  assert.equal(rateFetches.length, 0);
});

test('rates: USD-based rates with the source date and when the server read them', async () => {
  let t = Date.parse('2026-11-13T10:00:00Z');
  const { call, device, rateFetches } = setup({ now: () => t });
  const { token } = device();
  const res = await call(token, 'GET', '/v1/rates');
  assert.equal(res.status, 200);
  const out = await res.json();
  assert.equal(out.base, 'USD');
  assert.equal(out.date, '2026-11-12');
  assert.equal(out.fetched_at, '2026-11-13T10:00:00.000Z');
  assert.equal(out.rates.INR, 94.04);
  assert.equal(out.rates.USD, 1);
  assert.deepEqual(rateFetches, [RATES_URL]);
});

test('rates: cached for one hour, then read again', async () => {
  let t = Date.parse('2026-11-13T10:00:00Z');
  const opts: { now: () => number; rates?: unknown } = { now: () => t };
  const { call, device, rateFetches } = setup(opts);
  const { token } = device();
  await call(token, 'GET', '/v1/rates');
  t += RATES_TTL_MS - 1;
  await call(token, 'GET', '/v1/rates');
  assert.equal(rateFetches.length, 1);
  opts.rates = { base: 'USD', date: '2026-11-13', rates: { INR: 95 } };
  t += 2;
  const out = await (await call(token, 'GET', '/v1/rates')).json();
  assert.equal(rateFetches.length, 2);
  assert.equal(out.rates.INR, 95);
  assert.equal(out.date, '2026-11-13');
});

test('rates: a failed refresh keeps the last good rates and waits before trying again', async () => {
  let t = Date.parse('2026-11-13T10:00:00Z');
  const opts: { now: () => number; rates?: unknown } = { now: () => t };
  const { call, device, rateFetches } = setup(opts);
  const { token } = device();
  await call(token, 'GET', '/v1/rates');
  opts.rates = new Error('source down');
  t += RATES_TTL_MS + 1;
  const res = await call(token, 'GET', '/v1/rates');
  assert.equal(res.status, 200);
  assert.equal((await res.json()).rates.INR, 94.04);
  await call(token, 'GET', '/v1/rates');
  assert.equal(rateFetches.length, 2);
});

test('rates: no rates yet and a bad or failed source is a 502 with no detail', async () => {
  for (const rates of [new Error('boom secret'), { base: 'EUR', date: '2026-11-12', rates: { INR: 1 } }, { base: 'USD', date: 'x', rates: {} }, { base: 'USD', date: '2026-11-12', rates: { INR: -1 } }]) {
    const { call, device } = setup({ rates });
    const { token } = device();
    const res = await call(token, 'GET', '/v1/rates');
    assert.equal(res.status, 502);
    assert.ok(!(await res.text()).includes('secret'));
  }
});
