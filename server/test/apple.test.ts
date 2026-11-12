import { test } from 'node:test';
import assert from 'node:assert/strict';
import { generateKeyPairSync, sign, type KeyObject } from 'node:crypto';
import { createAppleVerifier, type AppleJwk } from '../src/apple.ts';
import { sha256 } from '../src/crypto.ts';
import { setup } from './helpers.ts';

const AUD = 'com.orseliyas.pip';
const NONCE = 'raw-nonce-0123456789abcdef';
const pair = (kid: string) => {
  const { publicKey, privateKey } = generateKeyPairSync('rsa', { modulusLength: 2048 });
  return { kid, privateKey, jwk: { ...(publicKey.export({ format: 'jwk' }) as { kty: string; n: string; e: string }), kid, alg: 'RS256', use: 'sig' } as AppleJwk };
};
const apple = pair('apple-key-1');
const other = pair('apple-key-1');
const b64 = (o: unknown) => Buffer.from(JSON.stringify(o)).toString('base64url');

function token(claims: Record<string, unknown> = {}, o: { key?: KeyObject; kid?: string; alg?: string } = {}) {
  const head = b64({ alg: o.alg ?? 'RS256', kid: o.kid ?? apple.kid });
  const body = b64({
    iss: 'https://appleid.apple.com', aud: AUD, sub: '001234.abcdef.5678', nonce: sha256(NONCE),
    iat: Math.floor(Date.now() / 1000), exp: Math.floor(Date.now() / 1000) + 600, ...claims,
  });
  const sig = sign('RSA-SHA256', Buffer.from(`${head}.${body}`), o.key ?? apple.privateKey).toString('base64url');
  return `${head}.${body}.${sig}`;
}
function verifier(keys: AppleJwk[] = [apple.jwk]) {
  let fetches = 0;
  const verify = createAppleVerifier({ audience: AUD, fetchKeys: async () => { fetches++; return keys; } });
  return { verify, fetches: () => fetches };
}

test('apple: a good token gives the sub, and the JWKS is fetched once', async () => {
  const v = verifier();
  assert.deepEqual(await v.verify(token(), NONCE), { sub: '001234.abcdef.5678' });
  await v.verify(token({ sub: 'someone-else' }), NONCE);
  assert.equal(v.fetches(), 1);
});

test('apple: bad signature is rejected', async () => {
  const v = verifier();
  await assert.rejects(v.verify(token({}, { key: other.privateKey }), NONCE), /bad signature/);
  const [h, , s] = token().split('.');
  await assert.rejects(v.verify(`${h}.${b64({ iss: 'https://appleid.apple.com', aud: AUD, sub: 'attacker', nonce: sha256(NONCE), exp: 9e9 })}.${s}`, NONCE), /bad signature/);
});

test('apple: alg none and HS256 are rejected', async () => {
  const v = verifier();
  const [, b] = token().split('.');
  await assert.rejects(v.verify(`${b64({ alg: 'none', kid: apple.kid })}.${b}.`, NONCE), /bad header/);
  await assert.rejects(v.verify(token({}, { alg: 'HS256' }), NONCE), /bad header/);
});

test('apple: wrong aud, wrong iss, expired and wrong nonce are rejected', async () => {
  const v = verifier();
  await assert.rejects(v.verify(token({ aud: 'com.evil.app' }), NONCE), /bad aud/);
  await assert.rejects(v.verify(token({ iss: 'https://evil.example' }), NONCE), /bad iss/);
  await assert.rejects(v.verify(token({ exp: Math.floor(Date.now() / 1000) - 1 }), NONCE), /expired/);
  await assert.rejects(v.verify(token(), 'another-raw-nonce-000000'), /bad nonce/);
  await assert.rejects(v.verify(token({ nonce: NONCE }), NONCE), /bad nonce/);
  await assert.rejects(v.verify(token({ nonce: undefined }), NONCE), /bad nonce/);
});

test('apple: unknown key id is rejected and does not refetch on every call', async () => {
  const v = verifier();
  await assert.rejects(v.verify(token({}, { kid: 'nope' }), NONCE), /unknown key id/);
  await assert.rejects(v.verify(token({}, { kid: 'nope' }), NONCE), /unknown key id/);
  assert.equal(v.fetches(), 1);
});

test('POST /v1/auth/apple: signs in, reuses the user, stores only hashes', async () => {
  const created: string[] = [];
  const s = setup({ apple: verifier().verify, onNewUser: (id) => created.push(id) });
  const post = (b: unknown) => s.call(null, 'POST', '/v1/auth/apple', b);

  const r1 = await post({ identity_token: token(), nonce: NONCE });
  assert.equal(r1.status, 200);
  const t1 = (await r1.json()).device_token as string;
  assert.match(t1, /^pkd_/);
  assert.equal((await s.call(t1, 'GET', '/v1/me')).status, 200);

  const t2 = (await (await post({ identity_token: token(), nonce: NONCE })).json()).device_token as string;
  assert.notEqual(t1, t2);
  const users = s.db.raw.prepare('SELECT id, apple_sub_hash FROM users').all() as { id: string; apple_sub_hash: string }[];
  assert.equal(users.length, 1);
  assert.deepEqual(created, [users[0].id]);
  assert.equal(s.db.userForTokenHash(sha256(t2)), users[0].id);

  const dump = JSON.stringify([users, s.db.raw.prepare('SELECT * FROM devices').all()]);
  for (const secret of ['001234.abcdef.5678', sha256('001234.abcdef.5678'), t1, t2]) assert.ok(!dump.includes(secret));

  await post({ identity_token: token({ sub: 'second-person' }), nonce: NONCE });
  assert.equal(created.length, 2);
});

test('POST /v1/auth/apple: every failure is the same 401', async () => {
  const s = setup({ apple: verifier().verify });
  const bodies: unknown[] = [
    { identity_token: token({}, { key: other.privateKey }), nonce: NONCE },
    { identity_token: token({ aud: 'com.evil.app' }), nonce: NONCE },
    { identity_token: token({ exp: 1 }), nonce: NONCE },
    { identity_token: token(), nonce: 'another-raw-nonce-000000' },
    { identity_token: 'not.a.jwt-but-long-enough-to-pass', nonce: NONCE },
    { nonce: NONCE },
    'garbage',
  ];
  for (const b of bodies) {
    const r = await s.call(null, 'POST', '/v1/auth/apple', b);
    assert.equal(r.status, 401);
    assert.deepEqual(await r.json(), { error: 'unauthorized' });
  }
  assert.equal((s.db.raw.prepare('SELECT COUNT(*) AS n FROM users').get() as { n: number }).n, 0);
});

test('POST /v1/auth/apple: rate limited per client', async () => {
  const s = setup({ apple: verifier().verify });
  let last = 0;
  for (let i = 0; i < 11; i++) last = (await s.call(null, 'POST', '/v1/auth/apple', { nonce: NONCE })).status;
  assert.equal(last, 429);
});

const DEVICE = '3f0e6c1a-8a55-4a57-9d59-0c4d2f6f7b11';

test('POST /v1/auth/apple/link: attaches the Apple account to the device account, and keeps its data and token', async () => {
  const s = setup({ apple: verifier().verify });
  const device = (await (await s.call(null, 'POST', '/v1/auth/device', { device_id: DEVICE })).json()).device_token as string;
  const owner = s.db.userForTokenHash(sha256(device));
  const r = await s.call(device, 'POST', '/v1/auth/apple/link', { identity_token: token(), nonce: NONCE });
  assert.equal(r.status, 200);
  assert.deepEqual(await r.json(), { linked: true, recovered: false });
  const users = s.db.raw.prepare('SELECT id, apple_sub_hash FROM users').all() as { id: string; apple_sub_hash: string | null }[];
  assert.equal(users.length, 1);
  assert.ok(users[0].apple_sub_hash);
  assert.ok(!JSON.stringify(users).includes('001234.abcdef.5678'), 'only a hash of the Apple id is stored');
  assert.equal(users[0].id, owner);
  assert.equal(s.db.userForTokenHash(sha256(device)), owner, 'the device token still works for the same user');
  // Again from the same account: still linked, nothing new.
  assert.deepEqual(await (await s.call(device, 'POST', '/v1/auth/apple/link', { identity_token: token(), nonce: NONCE })).json(), { linked: true, recovered: false });
});

test('POST /v1/auth/apple/link: a re-install gets the earlier account and its data back', async () => {
  const s = setup({ apple: verifier().verify });
  const first = (await (await s.call(null, 'POST', '/v1/auth/device', { device_id: DEVICE })).json()).device_token as string;
  await s.call(first, 'POST', '/v1/auth/apple/link', { identity_token: token(), nonce: NONCE });

  const fresh = (await (await s.call(null, 'POST', '/v1/auth/device', { device_id: DEVICE })).json()).device_token as string;
  assert.notEqual(s.db.userForTokenHash(sha256(fresh)), s.db.userForTokenHash(sha256(first)), 'a new install starts as a new user');
  const r = await s.call(fresh, 'POST', '/v1/auth/apple/link', { identity_token: token(), nonce: NONCE });
  assert.equal(r.status, 200);
  const body = await r.json();
  assert.equal(body.recovered, true);
  assert.match(body.device_token, /^pkd_/);
  assert.notEqual(body.device_token, first);
  assert.equal(s.db.userForTokenHash(sha256(body.device_token)), s.db.userForTokenHash(sha256(first)));
  // Another person's Apple account never reaches this user.
  const other = (await (await s.call(null, 'POST', '/v1/auth/device', { device_id: DEVICE })).json()).device_token as string;
  assert.deepEqual(await (await s.call(other, 'POST', '/v1/auth/apple/link', { identity_token: token({ sub: 'second-person' }), nonce: NONCE })).json(), { linked: true, recovered: false });
  assert.notEqual(s.db.userForTokenHash(sha256(other)), s.db.userForTokenHash(sha256(first)));
});

test('POST /v1/auth/apple/link: a bad Apple token, a missing device token or a second Apple account is refused', async () => {
  const s = setup({ apple: verifier().verify });
  const device = (await (await s.call(null, 'POST', '/v1/auth/device', { device_id: DEVICE })).json()).device_token as string;
  const bad: unknown[] = [
    {}, { identity_token: token() }, { identity_token: token(), nonce: 'another-raw-nonce-000000' },
    { identity_token: token({ aud: 'com.evil.app' }), nonce: NONCE }, { identity_token: token({ exp: Math.floor(Date.now() / 1000) - 1 }), nonce: NONCE },
    { identity_token: token().slice(0, -6) + 'AAAAAA', nonce: NONCE },
  ];
  for (const b of bad) {
    const r = await s.call(device, 'POST', '/v1/auth/apple/link', b);
    assert.equal(r.status, 401);
    assert.deepEqual(await r.json(), { error: 'unauthorized' });
  }
  assert.equal((s.db.raw.prepare('SELECT COUNT(*) AS n FROM users WHERE apple_sub_hash IS NOT NULL').get() as { n: number }).n, 0);
  assert.equal((await s.call(null, 'POST', '/v1/auth/apple/link', { identity_token: token(), nonce: NONCE })).status, 401, 'no device token, no link');

  assert.equal((await s.call(device, 'POST', '/v1/auth/apple/link', { identity_token: token(), nonce: NONCE })).status, 200);
  const second = await s.call(device, 'POST', '/v1/auth/apple/link', { identity_token: token({ sub: 'second-person' }), nonce: NONCE });
  assert.equal(second.status, 409);
  assert.equal((s.db.raw.prepare('SELECT COUNT(*) AS n FROM users').get() as { n: number }).n, 1);
});
