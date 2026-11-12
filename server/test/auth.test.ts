import { test } from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { config } from '../src/config.ts';
import { randomToken, sha256 } from '../src/crypto.ts';
import { setup } from './helpers.ts';

const PW = 'blue kettle on the stove';
const PNG = Buffer.from('89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4890000000d4944415478da63f8ffff3f0005fe02fea7d6a4c00000000049454e44ae426082', 'hex');

type S = ReturnType<typeof setup>;
const json = async (r: Response) => ({ status: r.status, body: (await r.json()) as any });

/** Sign-up and its emailed code: returns the session tokens. */
async function signUp(s: S, email: string, password = PW) {
  assert.equal((await s.call(null, 'POST', '/v1/auth/email/signup', { email, password })).status, 202);
  const code = s.codeFor(email.toLowerCase(), 'verify');
  assert.ok(code, 'a verify code was mailed');
  const r = await json(await s.call(null, 'POST', '/v1/auth/email/verify', { email, code, password }));
  assert.equal(r.status, 200);
  return r.body as { access_token: string; refresh_token: string };
}
const login = (s: S, email: string, password: string) => s.call(null, 'POST', '/v1/auth/email/login', { email, password });
const upload = (s: S, token: string) => s.app.request('/v1/drawings', { method: 'POST', headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'image/png', 'X-User-Action': 'tap' }, body: PNG });
const count = (s: S, table: string, where = '1', ...args: string[]) =>
  (s.db.raw.prepare(`SELECT COUNT(*) AS n FROM ${table} WHERE ${where}`).get(...args) as { n: number }).n;

test('email: sign up, confirm by code, sign in; the email is stored only hashed and encrypted', async () => {
  const s = setup();
  const t = await signUp(s, 'Ana.Silva@Example.com');
  assert.match(t.access_token, /^pat_/);
  assert.match(t.refresh_token, /^prt_/);
  const me = await json(await s.call(t.access_token, 'GET', '/v1/me'));
  assert.deepEqual(me.body, { ok: true, email: 'ana.silva@example.com', email_verified: true, apple: false, password: true, anonymous: false });

  const dump = JSON.stringify(s.db.raw.prepare('SELECT * FROM users').all());
  assert.ok(!dump.toLowerCase().includes('ana.silva'), 'no plaintext email in the users table');
  assert.ok(!dump.includes(PW), 'no plaintext password');
  assert.ok(!dump.includes(sha256('ana.silva@example.com')), 'the lookup hash is keyed, not a plain SHA-256');
  for (const table of ['access_tokens', 'refresh_tokens']) {
    const rows = JSON.stringify(s.db.raw.prepare(`SELECT * FROM ${table}`).all());
    assert.ok(!rows.includes(t.access_token) && !rows.includes(t.refresh_token), `${table} holds only hashes`);
  }
  assert.equal((await login(s, 'ANA.SILVA@example.com ', PW)).status, 200, 'email case and spaces do not matter');
});

test('email: sign-in before the code is confirmed answers like a wrong password', async () => {
  const s = setup();
  await s.call(null, 'POST', '/v1/auth/email/signup', { email: 'kai@example.com', password: PW });
  assert.deepEqual(await json(await login(s, 'kai@example.com', PW)), { status: 401, body: { error: 'wrong email or password' } });
});

test('email: password rules: 10+ characters, not common, not the email; any language works', async () => {
  const s = setup();
  for (const password of ['short', 'qwertyuiop', 'Password123', 'aaaaaaaaaaaa', 'priya.nair2024']) {
    const r = await json(await s.call(null, 'POST', '/v1/auth/email/signup', { email: 'priya.nair@example.com', password }));
    assert.equal(r.status, 400, password);
    assert.ok(typeof r.body.error === 'string' && r.body.error.length < 80);
  }
  assert.equal(count(s, 'users'), 0);
  // Composed and decomposed é are one password.
  await signUp(s, 'jose@example.com', 'café con leche y pan');
  assert.equal((await login(s, 'jose@example.com', 'café con leche y pan')).status, 200);
});

test('enumeration: sign-up, sign-in and forgot answer the same for a known and an unknown email', async () => {
  const s = setup();
  await signUp(s, 'known@example.com');
  const a = await json(await s.call(null, 'POST', '/v1/auth/email/signup', { email: 'known@example.com', password: 'another fine password' }));
  const b = await json(await s.call(null, 'POST', '/v1/auth/email/signup', { email: 'new@example.com', password: 'another fine password' }));
  assert.deepEqual(a, b);
  assert.equal(s.mails.at(-2)?.kind, 'exists', 'the owner of the known email gets a note, not a code');
  assert.equal(s.mails.at(-2)?.code, undefined);

  const wrong = await json(await login(s, 'known@example.com', 'not the password!'));
  const unknown = await json(await login(s, 'nobody@example.com', 'not the password!'));
  assert.deepEqual(wrong, unknown);
  assert.deepEqual(wrong, { status: 401, body: { error: 'wrong email or password' } });

  const f1 = await json(await s.call(null, 'POST', '/v1/auth/password/forgot', { email: 'known@example.com' }));
  const f2 = await json(await s.call(null, 'POST', '/v1/auth/password/forgot', { email: 'nobody@example.com' }));
  assert.deepEqual(f1, f2);
});

test('timing: an unknown email still runs a full password hash', async () => {
  const s = setup();
  await signUp(s, 'known@example.com');
  await login(s, 'warm@example.com', 'warm up the dummy hash');
  const time = async (email: string) => {
    const t0 = performance.now();
    await login(s, email, 'not the password!');
    return performance.now() - t0;
  };
  const known: number[] = [], unknown: number[] = [];
  for (let i = 0; i < 3; i++) {
    known.push(await time('known@example.com'));
    unknown.push(await time(`nobody${i}@example.com`));
  }
  const med = (xs: number[]) => xs.sort((x, y) => x - y)[1];
  assert.ok(med(unknown) > med(known) * 0.5 && med(unknown) < med(known) * 2, `known ${med(known)} ms, unknown ${med(unknown)} ms`);
});

test('brute force: 5 misses lock the email with a backoff that doubles; a known and an unknown email lock alike', async () => {
  let t = Date.parse('2026-11-12T10:00:00Z');
  const s = setup({ now: () => t });
  await signUp(s, 'shop@example.com');
  const statuses = async (email: string, n: number, password = 'not the password!') => {
    const out: number[] = [];
    for (let i = 0; i < n; i++) out.push((await login(s, email, password)).status);
    return out;
  };
  assert.deepEqual(await statuses('shop@example.com', 6), [401, 401, 401, 401, 401, 429]);
  assert.deepEqual(await statuses('ghost@example.com', 6), [401, 401, 401, 401, 401, 429]);
  const locked = await login(s, 'shop@example.com', PW);
  assert.equal(locked.status, 429, 'the right password waits too');
  assert.equal(locked.headers.get('retry-after'), '30');
  t += 31_000;
  assert.equal((await login(s, 'shop@example.com', 'not the password!')).status, 401);
  assert.equal((await login(s, 'shop@example.com', PW)).headers.get('retry-after'), '60', 'the next lock is twice as long');
  t += 61_000;
  assert.equal((await login(s, 'shop@example.com', PW)).status, 200);
  assert.deepEqual(await statuses('shop@example.com', 1), [401], 'a good sign-in clears the count');
});

test('brute force: sign-in is limited per client IP across emails', async () => {
  const s = setup();
  const out: number[] = [];
  for (let i = 0; i < config.rateLimit.emailAuth.limit + 1; i++) out.push((await login(s, `p${i}@example.com`, 'not the password!')).status);
  assert.equal(out.at(-1), 429);
});

test('codes: a wrong code counts; after 5 the code is dead; codes expire after 15 minutes', async () => {
  let t = Date.parse('2026-11-12T10:00:00Z');
  const s = setup({ now: () => t });
  await s.call(null, 'POST', '/v1/auth/email/signup', { email: 'lee@example.com', password: PW });
  const code = s.codeFor('lee@example.com', 'verify')!;
  const wrong = code === '000000' ? '111111' : '000000';
  for (let i = 0; i < 5; i++) assert.equal((await s.call(null, 'POST', '/v1/auth/email/verify', { email: 'lee@example.com', code: wrong, password: PW })).status, 400);
  assert.equal((await s.call(null, 'POST', '/v1/auth/email/verify', { email: 'lee@example.com', code, password: PW })).status, 400, 'the right code no longer works');

  await s.call(null, 'POST', '/v1/auth/email/signup', { email: 'lee@example.com', password: PW });
  const fresh = s.codeFor('lee@example.com', 'verify')!;
  t += config.auth.codeTtlMs + 1;
  assert.equal((await s.call(null, 'POST', '/v1/auth/email/verify', { email: 'lee@example.com', code: fresh, password: PW })).status, 400);
  const unknown = await json(await s.call(null, 'POST', '/v1/auth/email/verify', { email: 'nobody@example.com', code: '123456', password: PW }));
  assert.deepEqual(unknown, { status: 400, body: { error: 'that code is wrong or has expired' } });
});

test('reset: the emailed code sets a new password, ends every session and the old password', async () => {
  const s = setup();
  const first = await signUp(s, 'teacher@school.edu');
  const second = await json(await login(s, 'teacher@school.edu', PW));
  await s.call(null, 'POST', '/v1/auth/password/forgot', { email: 'teacher@school.edu' });
  const code = s.codeFor('teacher@school.edu', 'reset')!;
  assert.equal((await s.call(null, 'POST', '/v1/auth/password/reset', { email: 'teacher@school.edu', code, password: 'short' })).status, 400);
  const r = await json(await s.call(null, 'POST', '/v1/auth/password/reset', { email: 'teacher@school.edu', code, password: 'a whole new sentence' }));
  assert.equal(r.status, 200);
  assert.equal(s.whoIs(first.access_token), undefined);
  assert.equal(s.whoIs(second.body.access_token), undefined);
  assert.equal((await s.call(null, 'POST', '/v1/auth/refresh', { refresh_token: first.refresh_token })).status, 401);
  assert.equal((await login(s, 'teacher@school.edu', PW)).status, 401);
  assert.equal((await login(s, 'teacher@school.edu', 'a whole new sentence')).status, 200);
  assert.equal((await s.call(null, 'POST', '/v1/auth/password/reset', { email: 'teacher@school.edu', code, password: 'yet another sentence' })).status, 400, 'a code works once');
});

test('refresh: rotation gives a new pair and ends the old access token', async () => {
  const s = setup();
  const t = await signUp(s, 'free@lance.io');
  const r = await json(await s.call(null, 'POST', '/v1/auth/refresh', { refresh_token: t.refresh_token }));
  assert.equal(r.status, 200);
  assert.notEqual(r.body.refresh_token, t.refresh_token);
  assert.equal(r.body.expires_in, 900);
  assert.equal(s.whoIs(t.access_token), undefined, 'the old access token died with the rotation');
  assert.ok(s.whoIs(r.body.access_token));
});

test('refresh: a reused refresh token deletes the whole family, the thief\'s and the owner\'s tokens', async () => {
  const s = setup();
  const t = await signUp(s, 'victim@example.com');
  const other = await json(await login(s, 'victim@example.com', PW));
  const owner = (await json(await s.call(null, 'POST', '/v1/auth/refresh', { refresh_token: t.refresh_token }))).body;
  const replay = await s.call(null, 'POST', '/v1/auth/refresh', { refresh_token: t.refresh_token });
  assert.equal(replay.status, 401);
  assert.equal(s.whoIs(owner.access_token), undefined);
  assert.equal((await s.call(null, 'POST', '/v1/auth/refresh', { refresh_token: owner.refresh_token })).status, 401);
  assert.ok(s.whoIs(other.body.access_token), 'another session of the same user stays');
});

test('access tokens expire after 15 minutes; refresh tokens after 30 days', async () => {
  let t = Date.parse('2026-11-12T10:00:00Z');
  const s = setup({ now: () => t });
  const tok = await signUp(s, 'clock@example.com');
  t += config.auth.accessTtlMs + 1;
  assert.equal((await s.call(tok.access_token, 'GET', '/v1/me')).status, 401);
  const r = (await json(await s.call(null, 'POST', '/v1/auth/refresh', { refresh_token: tok.refresh_token }))).body;
  assert.equal((await s.call(r.access_token, 'GET', '/v1/me')).status, 200);
  t += config.auth.refreshTtlMs + 1;
  assert.equal((await s.call(null, 'POST', '/v1/auth/refresh', { refresh_token: r.refresh_token })).status, 401);
});

test('logout ends this session only; log out everywhere ends all of them', async () => {
  const s = setup();
  const a = await signUp(s, 'two.phones@example.com');
  const b = (await json(await login(s, 'two.phones@example.com', PW))).body;
  const c = (await json(await login(s, 'two.phones@example.com', PW))).body;
  assert.equal((await s.call(a.access_token, 'POST', '/v1/auth/logout')).status, 200);
  assert.equal((await s.call(a.access_token, 'GET', '/v1/me')).status, 401);
  assert.equal((await s.call(null, 'POST', '/v1/auth/refresh', { refresh_token: a.refresh_token })).status, 401);
  assert.equal((await s.call(b.access_token, 'GET', '/v1/me')).status, 200);
  assert.equal((await s.call(b.access_token, 'POST', '/v1/auth/logout-all')).status, 200);
  for (const t of [b, c]) {
    assert.equal((await s.call(t.access_token, 'GET', '/v1/me')).status, 401);
    assert.equal((await s.call(null, 'POST', '/v1/auth/refresh', { refresh_token: t.refresh_token })).status, 401);
  }
  assert.equal((await login(s, 'two.phones@example.com', PW)).status, 200, 'the account itself stays');
});

test('delete account: every row of the user goes, their links stop working, other users keep theirs', async () => {
  const s = setup();
  const gone = await signUp(s, 'leaving@example.com');
  const stays = await signUp(s, 'staying@example.com');
  const goneUrl = new URL((await (await upload(s, gone.access_token)).json()).url).pathname;
  const staysUrl = new URL((await (await upload(s, stays.access_token)).json()).url).pathname;
  const goneId = s.whoIs(gone.access_token)!;
  await s.call(gone.access_token, 'POST', '/v1/auth/password/forgot', { email: 'leaving@example.com' });
  await login(s, 'leaving@example.com', 'wrong password here');

  assert.equal((await s.call(gone.access_token, 'DELETE', '/v1/account')).status, 400, 'no confirm, no delete');
  assert.equal((await s.call(gone.access_token, 'DELETE', '/v1/account', { password: 'not the password!' })).status, 403);
  const r = await json(await s.call(gone.access_token, 'DELETE', '/v1/account', { password: PW }));
  assert.deepEqual(r, { status: 200, body: { deleted: true } });
  for (const table of ['users']) assert.equal(count(s, table, 'id = ?', goneId), 0);
  for (const table of ['sessions', 'shared_images', 'email_codes', 'devices']) assert.equal(count(s, table, 'user_id = ?', goneId), 0, table);
  assert.equal(count(s, 'access_tokens'), count(s, 'access_tokens', 'session_id IN (SELECT id FROM sessions)'));
  assert.equal(count(s, 'login_failures'), 0, 'the lockout row of the email goes too');
  assert.equal((await s.app.request(`${goneUrl}.png`)).status, 404);
  assert.equal((await s.app.request(`${staysUrl}.png`)).status, 200);
  assert.equal((await s.call(gone.access_token, 'GET', '/v1/me')).status, 401);
  assert.equal((await s.call(null, 'POST', '/v1/auth/refresh', { refresh_token: gone.refresh_token })).status, 401);
  assert.equal((await login(s, 'leaving@example.com', PW)).status, 401);
  const again = await signUp(s, 'leaving@example.com');
  assert.notEqual(s.whoIs(again.access_token), goneId, 'the email can start a new, empty account');
});

test('upgrade: a device account adds an email and keeps its id and its drawings', async () => {
  const s = setup();
  const dev = (await json(await s.call(null, 'POST', '/v1/auth/device', { device_id: randomUUID() }))).body;
  const id = s.whoIs(dev.access_token)!;
  assert.equal((await upload(s, dev.access_token)).status, 200);
  assert.equal((await s.call(dev.access_token, 'POST', '/v1/auth/email/link', { email: 'student@uni.edu', password: PW })).status, 202);
  const code = s.codeFor('student@uni.edu', 'link')!;
  assert.equal((await s.call(dev.access_token, 'POST', '/v1/auth/email/link/verify', { code: '000000' === code ? '111111' : '000000' })).status, 400);
  assert.deepEqual((await json(await s.call(dev.access_token, 'POST', '/v1/auth/email/link/verify', { code }))).body, { linked: true });
  assert.equal(s.whoIs(dev.access_token), id, 'the same session keeps working');
  const t = (await json(await login(s, 'student@uni.edu', PW))).body;
  assert.equal(s.whoIs(t.access_token), id);
  assert.equal(count(s, 'shared_images', 'user_id = ?', id), 1);
  assert.equal((await s.call(dev.access_token, 'POST', '/v1/auth/email/link', { email: 'second@uni.edu', password: PW })).status, 409);
});

test('upgrade: an email that has an account gets a note; the reply is the same and the link never happens', async () => {
  const s = setup();
  await signUp(s, 'taken@example.com');
  const { token } = s.device();
  const r = await json(await s.call(token, 'POST', '/v1/auth/email/link', { email: 'taken@example.com', password: PW }));
  assert.deepEqual(r, { status: 202, body: { status: 'check_email' } });
  assert.equal(s.mails.at(-1)?.kind, 'exists');
  assert.equal((await s.call(token, 'POST', '/v1/auth/email/link/verify', { code: '123456' })).status, 400);
});

test('legacy device token: traded once for a session, then dead', async () => {
  const s = setup();
  const userId = s.db.createUser();
  const old = randomToken('pkd');
  s.db.addDevice(userId, sha256(old), 'device');
  assert.equal((await s.call(old, 'GET', '/v1/me')).status, 401, 'no longer a bearer token');
  const r = await json(await s.call(null, 'POST', '/v1/auth/device/exchange', { device_token: old }));
  assert.equal(r.status, 200);
  assert.equal(s.whoIs(r.body.access_token), userId, 'the same user, so nothing is lost');
  assert.equal((await s.call(null, 'POST', '/v1/auth/device/exchange', { device_token: old })).status, 401);
});

test('logs: a whole auth flow never logs an email, password, code or token', async () => {
  const lines: string[] = [];
  const orig = console.log;
  process.env.LOG_SILENT = '0';
  console.log = (...a: unknown[]) => { lines.push(a.map(String).join(' ')); };
  try {
    const s = setup();
    const t = await signUp(s, 'secret.person@example.com');
    await login(s, 'secret.person@example.com', 'wrong password here');
    await s.call(null, 'POST', '/v1/auth/password/forgot', { email: 'secret.person@example.com' });
    await s.call(null, 'POST', '/v1/auth/refresh', { refresh_token: t.refresh_token });
    await s.call(null, 'POST', '/v1/auth/refresh', { refresh_token: t.refresh_token });
    const all = lines.join('\n');
    assert.ok(lines.length > 3, 'the flow logged something');
    for (const secret of ['secret.person', PW, 'wrong password', t.access_token, t.refresh_token, ...s.mails.map((m) => m.code).filter(Boolean) as string[]]) {
      assert.ok(!all.includes(secret), `log leaks ${secret.slice(0, 6)}...`);
    }
  } finally {
    console.log = orig;
    process.env.LOG_SILENT = '1';
  }
});

test('migration: a version-0 database moves to the current schema, keeps its rows and cascades deletes', async () => {
  const { DatabaseSync } = await import('node:sqlite');
  const { openDb, SCHEMA_VERSION } = await import('../src/db.ts');
  const { mkdtempSync } = await import('node:fs');
  const { join } = await import('node:path');
  const { tmpdir } = await import('node:os');
  const path = join(mkdtempSync(join(tmpdir(), 'pip-db-')), 'v0.db');
  const old = new DatabaseSync(path);
  old.exec(`CREATE TABLE users (id TEXT PRIMARY KEY, created_at INTEGER NOT NULL, apple_sub_hash TEXT);
    CREATE TABLE devices (token_hash TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id), label TEXT, created_at INTEGER NOT NULL);
    CREATE TABLE shared_images (id TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id), png BLOB NOT NULL, created_at INTEGER NOT NULL, expires_at INTEGER NOT NULL);
    INSERT INTO users VALUES ('u1', 1, NULL); INSERT INTO devices VALUES ('h1', 'u1', 'device', 1);
    INSERT INTO shared_images VALUES ('img1', 'u1', x'00', 1, 9999999999999);`);
  old.close();
  const db = openDb(path);
  assert.equal((db.raw.prepare('PRAGMA user_version').get() as { user_version: number }).user_version, SCHEMA_VERSION);
  assert.equal(db.takeDevice('h1'), 'u1', 'old device rows survive');
  db.addDevice('u1', 'h2', 'device');
  assert.ok(db.sharedImage('img1', 1));
  db.deleteUser('u1');
  assert.equal(db.sharedImage('img1', 1), undefined, 'drawings cascade');
  assert.equal(db.takeDevice('h2'), undefined, 'device rows cascade');
  db.raw.close();
  openDb(path).raw.close();
});

// ---- one test per finding of the security review (docs/SECURITY-AUTH.md)

test('F1: a second sign-up for an unconfirmed email cannot plant its password; the code holder sets it', async () => {
  const s = setup();
  await s.call(null, 'POST', '/v1/auth/email/signup', { email: 'victim@example.com', password: PW });
  await s.call(null, 'POST', '/v1/auth/email/signup', { email: 'victim@example.com', password: 'attacker sentence here' });
  const code = s.codeFor('victim@example.com', 'verify')!;
  assert.equal((await s.call(null, 'POST', '/v1/auth/email/verify', { email: 'victim@example.com', code, password: PW })).status, 200);
  assert.equal((await login(s, 'victim@example.com', 'attacker sentence here')).status, 401);
  assert.equal((await login(s, 'victim@example.com', PW)).status, 200);
});

test('F2: asking for codes over the mail limit makes no new code, and 10 wrong codes a day stop every code', async (t) => {
  // Many IPs: the IP limit is not what this test is about.
  const ipLimit = config.rateLimit.emailAuth.limit;
  config.rateLimit.emailAuth.limit = 1000;
  t.after(() => { config.rateLimit.emailAuth.limit = ipLimit; });
  const s = setup();
  await signUp(s, 'reset.me@example.com');
  for (let i = 0; i < 8; i++) await s.call(null, 'POST', '/v1/auth/password/forgot', { email: 'reset.me@example.com' });
  const codes = s.mails.filter((m) => m.kind === 'reset');
  assert.equal(codes.length, config.rateLimit.mailPerEmail.limit - 1, 'sign-up used one mail; the rest of the hour gives 4 resets');
  const live = codes.at(-1)!.code!;
  const id = s.db.userByEmailHash(s.cipher.lookupHash('email', 'reset.me@example.com'))!.id;
  assert.equal(s.db.code(id, 'reset')!.code_hash, s.cipher.lookupHash('code', `${id}:reset:${live}`), 'the last mailed code is still the live one');
  const bad = (n: number) => String((Number(live) + n) % 1_000_000).padStart(6, '0');
  for (let i = 1; i <= 10; i++) {
    if (i % 5 === 1) s.db.putCode({ userId: id, purpose: 'reset', codeHash: s.cipher.lookupHash('code', `${id}:reset:${live}`), expiresAt: Date.now() + 600_000 });
    await s.call(null, 'POST', '/v1/auth/password/reset', { email: 'reset.me@example.com', code: bad(i), password: 'a whole new sentence' });
  }
  assert.equal((await s.call(null, 'POST', '/v1/auth/password/reset', { email: 'reset.me@example.com', code: live, password: 'a whole new sentence' })).status, 400,
    'after 10 misses even the right code is refused');
});

test('F3: many wrong passwords at once still meet the lock after five', async () => {
  const s = setup();
  await signUp(s, 'race@example.com');
  config.trustProxy = true;
  try {
    const out = await Promise.all(Array.from({ length: 30 }, (_, i) =>
      Promise.resolve(s.call(null, 'POST', '/v1/auth/email/login', { email: 'race@example.com', password: 'not the password!' }, { 'X-Forwarded-For': `10.0.0.${i}` })).then((r) => r.status)));
    assert.equal(out.filter((x) => x === 401).length, config.auth.lockAfter, JSON.stringify(out));
  } finally {
    config.trustProxy = false;
  }
});

test('F4: after sign-up with a password, sign-in looks the same for a new email and a confirmed one', async () => {
  const s = setup();
  await signUp(s, 'confirmed@example.com');
  for (const email of ['confirmed@example.com', 'brand.new@example.com']) {
    await s.call(null, 'POST', '/v1/auth/email/signup', { email, password: 'probe sentence one' });
  }
  assert.deepEqual(await json(await login(s, 'confirmed@example.com', 'probe sentence one')), await json(await login(s, 'brand.new@example.com', 'probe sentence one')));
});

test('F5: filling the limiter with other keys does not reset a limited client', async () => {
  const { createLimiter } = await import('../src/http.ts');
  const l = createLimiter({ limit: 2, windowMs: 60_000 });
  l.hit('victim'); l.hit('victim');
  assert.equal(l.hit('victim'), true);
  for (let i = 0; i < 20_000; i++) l.hit(`k${i}`);
  assert.equal(l.hit('victim'), true, 'still limited');
});

test('F7: log out everywhere also ends live codes; deleted rows are zeroed', async () => {
  const s = setup();
  const t = await signUp(s, 'codes@example.com');
  await s.call(null, 'POST', '/v1/auth/password/forgot', { email: 'codes@example.com' });
  const code = s.codeFor('codes@example.com', 'reset')!;
  await s.call(t.access_token, 'POST', '/v1/auth/logout-all');
  assert.equal(count(s, 'email_codes'), 0);
  assert.equal((await s.call(null, 'POST', '/v1/auth/password/reset', { email: 'codes@example.com', code, password: 'a whole new sentence' })).status, 400);
  assert.equal((s.db.raw.prepare('PRAGMA secure_delete').get() as { secure_delete: number }).secure_delete, 1);
});

test('F9: deleting a password account needs the password; a stolen token alone cannot', async () => {
  const s = setup();
  const t = await signUp(s, 'keep.me@example.com');
  assert.equal((await s.call(t.access_token, 'DELETE', '/v1/account', { confirm: true })).status, 403);
  assert.equal((await login(s, 'keep.me@example.com', PW)).status, 200);
  const { token } = s.device();
  assert.equal((await s.call(token, 'DELETE', '/v1/account', { confirm: true })).status, 200, 'an account with no password confirms only');
});
