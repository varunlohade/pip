import { test } from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { config } from '../src/config.ts';
import { setup } from './helpers.ts';

// Many kinds of people, each through the whole server flow with a mocked model: sign-up, sign-in, explain (meanings the
// phone does not know), a drawn chart, send as link, logout, sign back in, and for some, delete. No paid call.
// Apple is a stand-in verifier here; the real one is tested in apple.test.ts.

type Kind = 'email' | 'apple' | 'both' | 'device';
type Persona = { name: string; kind: Kind; email?: string; password?: string; sub?: string; ask: string; topic: string };

const people: Persona[] = [
  { name: 'student', kind: 'email', email: 'maya.student@uni.edu', password: 'pizza after the library', ask: 'what does rizz mean', topic: 'photosynthesis' },
  { name: 'teacher', kind: 'email', email: 'mr.okafor@school.org', password: 'chalk dust every morning', ask: 'explain fractions', topic: 'fractions' },
  { name: 'small-shop owner', kind: 'both', email: 'orders@corner-shop.co', password: 'forty crates on tuesday', sub: 'apple.shop.001', ask: 'explain gross margin', topic: 'gross margin' },
  { name: 'freelancer', kind: 'email', email: 'sam@freelance.dev', password: 'invoices net thirty days', ask: 'explain net 30', topic: 'net 30' },
  { name: 'non-native speaker', kind: 'email', email: 'jose.garcia@ejemplo.es', password: 'contraseña muy segura de verdad', ask: '¿qué es inflación? explain inflation', topic: 'inflación' },
  { name: 'heavy emoji user', kind: 'email', email: 'emoji.fan@example.com', password: '\u{1F355}\u{1F355} pizza party \u{1F389}\u{1F389}', ask: 'explain \u{1F680} rockets', topic: 'rockets \u{1F680}' },
  { name: 'privacy-strict, no Full Access', kind: 'device', ask: '', topic: '' },
  { name: 'Apple-only', kind: 'apple', sub: 'apple.only.002', ask: 'explain black holes', topic: 'black holes' },
  { name: 'email-only', kind: 'email', email: 'only.email@example.net', password: 'just an email and words', ask: 'explain index funds', topic: 'index funds' },
  { name: 'both Apple and email', kind: 'both', email: 'both.ways@example.org', password: 'two doors one house', sub: 'apple.both.003', ask: 'explain apr', topic: 'apr' },
];

const PNG = Buffer.from('89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4890000000d4944415478da63f8ffff3f0005fe02fea7d6a4c00000000049454e44ae426082', 'hex');

function world() {
  config.trustProxy = true;
  let nonce = 0;
  const s = setup({ apple: async (tok) => ({ sub: tok.split('|')[1] }) });
  const appleBody = (sub: string) => ({ identity_token: `fake-apple-identity-token|${sub}`, nonce: `nonce-${++nonce}-0123456789abcdef` });
  return { s, appleBody };
}

async function run(w: ReturnType<typeof world>, p: Persona, ip: string) {
  const { s, appleBody } = w;
  const h = { 'X-Forwarded-For': ip };
  const call = (token: string | null, method: string, path: string, body?: unknown) => s.call(token, method, path, body, h);
  const ok = async (r: Response | Promise<Response>, status = 200) => {
    const res = await r;
    const body = await res.json();
    assert.equal(res.status, status, `${p.name}: ${JSON.stringify(body)}`);
    return body as any;
  };

  // Sign-up and first sign-in.
  let token: string;
  if (p.kind === 'device') {
    token = (await ok(call(null, 'POST', '/v1/auth/device', { device_id: randomUUID() }))).access_token;
  } else if (p.kind === 'apple') {
    token = (await ok(call(null, 'POST', '/v1/auth/apple', appleBody(p.sub!)))).access_token;
  } else {
    await ok(call(null, 'POST', '/v1/auth/email/signup', { email: p.email, password: p.password }), 202);
    token = (await ok(call(null, 'POST', '/v1/auth/email/verify', { email: p.email, code: s.codeFor(p.email!, 'verify'), password: p.password }))).access_token;
    if (p.kind === 'both') {
      await ok(call(token, 'POST', '/v1/auth/apple/link', appleBody(p.sub!)));
    }
  }
  const userId = s.whoIs(token)!;
  assert.ok(userId, p.name);

  // Sign in again the way this person does.
  if (p.kind === 'email' || p.kind === 'both') token = (await ok(call(null, 'POST', '/v1/auth/email/login', { email: p.email, password: p.password }))).access_token;
  if (p.kind === 'apple' || p.kind === 'both') assert.equal(s.whoIs((await ok(call(null, 'POST', '/v1/auth/apple', appleBody(p.sub!)))).access_token), userId);
  assert.equal(s.whoIs(token), userId);

  const me = await ok(call(token, 'GET', '/v1/me'));
  assert.equal(me.email, p.email ?? null, p.name);
  assert.equal(me.apple, p.kind === 'apple' || p.kind === 'both');
  assert.equal(me.anonymous, p.kind === 'device');

  // The privacy-strict person has no Full Access: the keyboard sends nothing, so they make no model call here either.
  let link: string | undefined;
  if (p.kind !== 'device') {
    const aiBefore = s.aiCalls.length;
    await ok(call(token, 'POST', '/v1/explain', { text: p.ask }));
    await ok(call(token, 'POST', '/v1/explain/visual', { topic: p.topic }));
    assert.deepEqual(s.aiCalls.slice(aiBefore).map((c) => c.fn), ['explain', 'visual'], p.name);
    link = (await ok(s.app.request('/v1/drawings', { method: 'POST', headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'image/png', 'X-User-Action': 'tap', ...h }, body: PNG }))).url;
  }

  // Logout: this session is dead; signing back in finds the same user and the same data.
  await ok(call(token, 'POST', '/v1/auth/logout'));
  assert.equal((await call(token, 'GET', '/v1/me')).status, 401, `${p.name}: logged out`);
  let back: string;
  if (p.kind === 'device') back = (await ok(call(null, 'POST', '/v1/auth/device', { device_id: randomUUID() }))).access_token;
  else if (p.kind === 'apple') back = (await ok(call(null, 'POST', '/v1/auth/apple', appleBody(p.sub!)))).access_token;
  else back = (await ok(call(null, 'POST', '/v1/auth/email/login', { email: p.email, password: p.password }))).access_token;
  if (p.kind === 'device') assert.notEqual(s.whoIs(back), userId, 'a device account is gone after logout, as the app warns');
  else assert.equal(s.whoIs(back), userId, `${p.name}: same account after sign-in again`);
  return { userId, token: back, link };
}

const rows = (s: ReturnType<typeof setup>, userId: string) =>
  (s.db.raw.prepare('SELECT COUNT(*) AS n FROM shared_images WHERE user_id = ?').get(userId) as { n: number }).n;

test('personas: each kind of person runs the whole flow; nobody sees anyone else', async (t) => {
  t.after(() => { config.trustProxy = false; });
  const w = world();
  const done: { p: Persona; userId: string; token: string; link?: string }[] = [];
  for (const [i, p] of people.entries()) done.push({ p, ...(await run(w, p, `198.51.100.${i + 1}`)) });

  const ids = new Set(done.map((d) => d.userId));
  assert.equal(ids.size, people.length, 'every person is their own user');
  for (const d of done) {
    const me = await (await w.s.call(d.token, 'GET', '/v1/me')).json();
    assert.equal(me.email, d.p.kind === 'device' ? null : d.p.email ?? null, `${d.p.name} sees only their own email`);
    assert.equal(rows(w.s, d.userId), d.link ? 1 : 0, `${d.p.name} owns only their own drawing`);
  }
  const users = JSON.stringify(w.s.db.raw.prepare('SELECT * FROM users').all());
  for (const p of people) if (p.email) assert.ok(!users.includes(p.email.split('@')[0]), `${p.name}: no plaintext email stored`);
});

test('personas: someone logs out and a different person signs in on the same phone; delete leaves the other untouched', async (t) => {
  t.after(() => { config.trustProxy = false; });
  const w = world();
  const ip = '203.0.113.50';
  const a = await run(w, people[0], ip);
  const b = await run(w, people[3], ip);
  assert.notEqual(a.userId, b.userId);
  assert.equal((await (await w.s.call(b.token, 'GET', '/v1/me')).json()).email, people[3].email);

  // A deletes their account (with the password); B's account and drawing stay; A's link is gone.
  assert.equal((await w.s.call(a.token, 'DELETE', '/v1/account', { password: people[0].password }, { 'X-Forwarded-For': ip })).status, 200);
  assert.equal(rows(w.s, a.userId), 0);
  assert.equal((await w.s.app.request(new URL(a.link!).pathname + '.png')).status, 404);
  assert.equal(rows(w.s, b.userId), 1);
  assert.equal((await w.s.app.request(new URL(b.link!).pathname + '.png')).status, 200);
  assert.equal((await w.s.call(b.token, 'GET', '/v1/me')).status, 200);
  assert.equal((await w.s.call(null, 'POST', '/v1/auth/email/login', { email: people[0].email, password: people[0].password }, { 'X-Forwarded-For': ip })).status, 401);
});
