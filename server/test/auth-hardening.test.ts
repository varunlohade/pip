import { test } from 'node:test';
import assert from 'node:assert/strict';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { config } from '../src/config.ts';
import { createLimiter, ipKey } from '../src/http.ts';
import { hashingStats } from '../src/password.ts';
import { setup } from './helpers.ts';

// The lessons the Muninn team found, checked on Pip. docs/SECURITY-AUTH.md, "Compared with Muninn".
type S = ReturnType<typeof setup>;
const PW = 'blue kettle on the stove';
// A stand-in for Apple: the identity token names the Apple user. The nonce goes through the server's own check.
const appleBody = (nonce: string, sub = 'ana') => ({ identity_token: `apple-user-${sub}-0123456789`, nonce });
const standInApple = async (identityToken: string) => ({ sub: identityToken });
const nonceFrom = async (s: S) => (await (await s.call(null, 'GET', '/v1/auth/apple/nonce')).json()).nonce as string;

async function signUp(s: S, email: string, password = PW) {
  assert.equal((await s.call(null, 'POST', '/v1/auth/email/signup', { email, password })).status, 202);
  const code = s.codeFor(email, 'verify');
  assert.equal((await s.call(null, 'POST', '/v1/auth/email/verify', { email, code, password })).status, 200);
}
const login = (s: S, email: string, password: string, headers: Record<string, string> = {}) =>
  s.call(null, 'POST', '/v1/auth/email/login', { email, password }, headers);

test('apple nonce: the server gives one out, it works once, and expires after 10 minutes', async () => {
  let t = Date.parse('2026-11-12T10:00:00Z');
  const s = setup({ now: () => t, apple: standInApple });
  const r = await s.call(null, 'GET', '/v1/auth/apple/nonce');
  assert.equal(r.status, 200);
  const { nonce, expires_in_s } = await r.json();
  assert.match(nonce, /^[A-Za-z0-9_-]{43}$/);
  assert.equal(expires_in_s, 600);
  assert.ok(!JSON.stringify(s.db.raw.prepare('SELECT * FROM apple_nonces').all()).includes(nonce), 'only a hash is stored');

  assert.equal((await s.call(null, 'POST', '/v1/auth/apple', appleBody(nonce))).status, 200);
  assert.equal((await s.call(null, 'POST', '/v1/auth/apple', appleBody(nonce))).status, 401, 'a used nonce is refused');

  const late = await nonceFrom(s);
  t += config.apple.nonceTtlMs + 1;
  assert.equal((await s.call(null, 'POST', '/v1/auth/apple', appleBody(late))).status, 401, 'an expired nonce is refused');

  // /v1/auth/apple/link spends the nonce the same way.
  const { access_token } = await (await s.call(null, 'POST', '/v1/auth/device', { device_id: randomUUID() })).json();
  const link = await nonceFrom(s);
  assert.equal((await s.call(access_token, 'POST', '/v1/auth/apple/link', appleBody(link, 'ben'))).status, 200);
  assert.equal((await s.call(access_token, 'POST', '/v1/auth/apple/link', appleBody(link, 'ben'))).status, 401);
});

test('apple nonce: when required, a nonce the server never gave out is refused; in test and dev it still works once', async () => {
  const s = setup({ apple: standInApple });
  const own = 'app-made-nonce-0123456789';
  config.apple.requireServerNonce = true;
  try {
    assert.equal((await s.call(null, 'POST', '/v1/auth/apple', appleBody(own))).status, 401);
    assert.equal((await s.call(null, 'POST', '/v1/auth/apple', appleBody(await nonceFrom(s)))).status, 200);
  } finally {
    config.apple.requireServerNonce = false;
  }
  assert.equal((await s.call(null, 'POST', '/v1/auth/apple', appleBody(own))).status, 200);
  assert.equal((await s.call(null, 'POST', '/v1/auth/apple', appleBody(own))).status, 401, 'still once');
});

test('scrypt: OWASP settings (N=2^16, r=8, p=2), and at most 2 hashes run at once', async () => {
  const s = setup();
  await signUp(s, 'params@example.com');
  const row = s.db.raw.prepare('SELECT password_hash FROM users WHERE password_hash IS NOT NULL').get() as { password_hash: string };
  assert.match(row.password_hash, /^scrypt\$16\$8\$2\$/);

  hashingStats(true);
  const out = await Promise.all(Array.from({ length: 6 }, async (_, i) => (await login(s, `parallel${i}@example.com`, 'not the password!')).status));
  assert.deepEqual(out, [401, 401, 401, 401, 401, 401], 'the queue waits; nobody is turned away within 10 s');
  assert.equal(hashingStats().peak, config.password.maxConcurrent);
  assert.equal(hashingStats().active, 0);
});

test('scrypt: a full queue answers 503 with Retry-After and gives the try back', async () => {
  const s = setup();
  await signUp(s, 'busy@example.com');
  const saved = { ...config.password };
  config.password.maxConcurrent = 1;
  config.password.queueTimeoutMs = 1;
  try {
    const rs = await Promise.all(Array.from({ length: 4 }, () => login(s, 'busy@example.com', 'not the password!')));
    const busy = rs.filter((r) => r.status === 503);
    assert.ok(busy.length >= 1, rs.map((r) => r.status).join());
    assert.equal(busy[0].headers.get('retry-after'), '5');
    const counted = (s.db.raw.prepare('SELECT MAX(count) AS count FROM auth_failures').get() as { count: number }).count;
    assert.equal(counted, rs.filter((r) => r.status === 401).length, 'only tries that were checked count');
  } finally {
    Object.assign(config.password, saved);
  }
  assert.equal(hashingStats().active, 0);
});

test('scrypt: a hash made with the older settings (N=2^15, p=1) still works and is made again at the next good login', async () => {
  const s = setup();
  await signUp(s, 'old@example.com');
  const salt = randomBytes(16);
  const old = `scrypt$15$8$1$${salt.toString('base64url')}$${scryptSync(PW.normalize('NFC'), salt, 32, { N: 2 ** 15, r: 8, p: 1, maxmem: 64 * 1024 * 1024 }).toString('base64url')}`;
  s.db.raw.prepare('UPDATE users SET password_hash = ?').run(old);
  assert.equal((await login(s, 'old@example.com', PW)).status, 200);
  const now = (s.db.raw.prepare('SELECT password_hash FROM users').get() as { password_hash: string }).password_hash;
  assert.match(now, /^scrypt\$16\$8\$2\$/);
  assert.equal((await login(s, 'old@example.com', PW)).status, 200);
});

test('ipKey: IPv6 by /64; IPv4 and mapped IPv4 as they are', () => {
  assert.equal(ipKey('203.0.113.7'), '203.0.113.7');
  assert.equal(ipKey('::ffff:203.0.113.7'), '203.0.113.7');
  assert.equal(ipKey('2001:db8:1:2:3:4:5:6'), '2001:db8:1:2::/64');
  assert.equal(ipKey('2001:0db8:0001:0002:ffff::1'), '2001:db8:1:2::/64');
  assert.equal(ipKey('2001:db8::1'), '2001:db8:0:0::/64');
  assert.equal(ipKey('fe80::1%en0'), 'fe80:0:0:0::/64');
});

test('limits: two IPv6 addresses in one /64 share a bucket; another /64 has its own', async () => {
  const s = setup();
  config.trustProxy = true;
  try {
    const from = async (ip: string) => (await s.call(null, 'POST', '/v1/auth/device', { device_id: randomUUID() }, { 'X-Forwarded-For': ip })).status;
    for (let i = 0; i < config.rateLimit.deviceAuth.limit; i++) assert.equal(await from(`2001:db8:1:2::${i + 1}`), 200);
    assert.equal(await from('2001:db8:1:2:ffff:ffff:ffff:ffff'), 429, 'the same /64');
    assert.equal(await from('2001:db8:1:3::1'), 200, 'another /64');
  } finally {
    config.trustProxy = false;
  }
});

test('limiter: a new window drops only ended windows; a full map drops the oldest live one, never all', (t) => {
  t.mock.timers.enable({ apis: ['Date'], now: 0 });
  const l = createLimiter({ limit: 1, windowMs: 1000, maxKeys: 3 });
  l.hit('a');
  t.mock.timers.tick(500);
  l.hit('b');
  l.hit('c');
  assert.equal(l.size(), 3);
  t.mock.timers.tick(600);
  l.hit('d');
  assert.equal(l.size(), 3, 'only the ended window of a went');
  assert.equal(l.hit('b'), true, 'b is still limited');
  l.hit('e');
  assert.equal(l.size(), 3, 'full: the oldest live window (b) went, the rest stay');
  assert.equal(l.hit('c'), true, 'c is still limited');
  assert.equal(l.hit('e'), true, 'e is still limited');
  t.mock.timers.tick(2000);
  l.hit('f');
  assert.equal(l.size(), 1, 'ended windows go even when the map is not full');
});
