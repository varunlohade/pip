import { test } from 'node:test';
import assert from 'node:assert/strict';
import { setup } from './helpers.ts';

test('suggest context: needs text or context; unknown fields rejected', async () => {
  const s = setup();
  const { token } = s.device();
  assert.equal((await s.call(token, 'POST', '/v1/suggest', { text: '' })).status, 400);
  assert.equal((await s.call(token, 'POST', '/v1/suggest', { text: ' ', context: ' ​ ' })).status, 400);
  assert.equal((await s.call(token, 'POST', '/v1/suggest', { text: 'hi', extra: 1 })).status, 400);
});
