import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createCipheriv, hkdfSync, randomBytes, randomUUID } from 'node:crypto';
import { config } from '../src/config.ts';
import { createCipher } from '../src/crypto.ts';
import { setup } from './helpers.ts';

const deviceAuth = async (s: ReturnType<typeof setup>, headers: Record<string, string>) =>
  (await s.call(null, 'POST', '/v1/auth/device', { device_id: randomUUID() }, headers)).status;

test('L2: spoofed X-Forwarded-For does not dodge the limit; behind a trusted proxy the right-most hop is the key', async () => {
  const s = setup();
  const st: number[] = [];
  for (let i = 0; i < config.rateLimit.deviceAuth.limit + 5; i++) st.push(await deviceAuth(s, { 'X-Forwarded-For': `10.0.${i >> 8}.${i & 255}` }));
  assert.ok(st.includes(429), 'rotating XFF must still hit the limit');

  config.trustProxy = true;
  try {
    const p = setup();
    const statuses: number[] = [];
    for (let i = 0; i < config.rateLimit.deviceAuth.limit + 5; i++) statuses.push(await deviceAuth(p, { 'X-Forwarded-For': `${i}.1.1.1, 198.51.100.7` }));
    assert.ok(statuses.includes(429), 'behind a trusted proxy the right-most hop is the key');
    assert.equal(await deviceAuth(p, { 'X-Forwarded-For': '198.51.100.7, 203.0.113.9' }), 200);
  } finally {
    config.trustProxy = false;
  }
});

test('L2: with CLIENT_IP_HEADER the Cloudflare header is the key, not the X-Forwarded-For edge hop', async () => {
  config.trustProxy = true;
  config.clientIpHeader = 'cf-connecting-ip';
  try {
    const p = setup();
    const statuses: number[] = [];
    for (let i = 0; i < config.rateLimit.deviceAuth.limit + 5; i++) {
      statuses.push(await deviceAuth(p, { 'CF-Connecting-IP': '198.51.100.7', 'X-Forwarded-For': `198.51.100.7, 104.22.${i}.1` }));
    }
    assert.ok(statuses.includes(429), 'rotating edge hops must not dodge the limit');
    assert.equal(await deviceAuth(p, { 'CF-Connecting-IP': '203.0.113.9' }), 200);
  } finally {
    config.trustProxy = false;
    config.clientIpHeader = '';
  }
});

test('crypto: a truncated GCM tag is rejected (Node 26 already rejects it; authTagLength pins it)', () => {
  const master = randomBytes(32);
  const cipher = createCipher(master);
  const key = Buffer.from(hkdfSync('sha256', master, Buffer.from('u1'), 'pip/data/v1', 32));
  const iv = randomBytes(12);
  const c = createCipheriv('aes-256-gcm', key, iv);
  c.setAAD(Buffer.from('u1'));
  c.update('');
  c.final();
  const blob = 'v1:' + Buffer.concat([iv, c.getAuthTag().subarray(0, 4)]).toString('base64');
  assert.throws(() => cipher.decrypt('u1', blob));
});
