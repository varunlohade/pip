import { test } from 'node:test';
import assert from 'node:assert/strict';
import { config } from '../src/config.ts';
import { setup } from './helpers.ts';

const PNG_MAGIC = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
const png = (size = 64): Uint8Array<ArrayBuffer> => {
  const b = new Uint8Array(size);
  b.set(PNG_MAGIC);
  for (let i = PNG_MAGIC.length; i < size; i++) b[i] = i % 251;
  return b;
};

function env(opts: { now?: () => number } = {}) {
  const s = setup(opts);
  const upload = (token: string | null, body: Uint8Array<ArrayBuffer>, type = 'image/png') =>
    s.app.request('/v1/drawings', {
      method: 'POST',
      headers: { 'Content-Type': type, ...(token ? { Authorization: `Bearer ${token}` } : {}) },
      body: body as BodyInit,
    });
  const view = (path: string) => s.app.request(path);
  return { ...s, upload, view };
}

test('share: a PNG uploads and its link serves exactly that image, as image/png, with no user data', async () => {
  const { upload, view, device } = env();
  const { token, userId } = device();
  const image = png(300);
  const res = await upload(token, image);
  assert.equal(res.status, 200);
  const out = await res.json();
  const m = /^http:\/\/localhost\/d\/([A-Za-z0-9_-]{22})\.png$/.exec(out.url);
  assert.ok(m, out.url);
  assert.ok(Date.parse(out.expires_at) > Date.now() + 29 * 86_400_000);
  const got = await view(new URL(out.url).pathname);
  assert.equal(got.status, 200);
  assert.equal(got.headers.get('content-type'), 'image/png');
  assert.equal(got.headers.get('x-content-type-options'), 'nosniff');
  assert.equal(got.headers.get('content-security-policy'), "default-src 'none'");
  assert.deepEqual(new Uint8Array(await got.arrayBuffer()), image);
  assert.ok(!out.url.includes(userId));
  assert.equal(got.headers.get('set-cookie'), null);
});

test('share: no token is 401; not a PNG is 400; over 1 MB is 413; nothing is stored', async () => {
  const { upload, device, db } = env();
  const { token } = device();
  assert.equal((await upload(null, png())).status, 401);
  assert.equal((await upload(token, png(), 'application/json')).status, 400);
  assert.equal((await upload(token, new TextEncoder().encode('GIF89a not a png at all'))).status, 400);
  assert.equal((await upload(token, png(config.sharedImage.maxBytes + 1))).status, 413);
  assert.equal((db.raw.prepare('SELECT COUNT(*) AS n FROM shared_images').get() as { n: number }).n, 0);
  assert.equal((await upload(token, png(config.sharedImage.maxBytes))).status, 200, 'exactly 1 MB is fine');
});

test('share: a link stops working after 30 days, and expired images are deleted', async () => {
  let t = Date.parse('2026-11-12T10:00:00Z');
  const { upload, view, device, db } = env({ now: () => t });
  const { token } = device();
  const path = new URL((await (await upload(token, png())).json()).url).pathname;
  t += config.sharedImage.ttlMs - 1000;
  assert.equal((await view(path)).status, 200);
  t += 2000;
  assert.equal((await view(path)).status, 404);
  await upload(token, png());
  assert.equal((db.raw.prepare('SELECT COUNT(*) AS n FROM shared_images').get() as { n: number }).n, 1, 'the expired row is gone');
});

test('share: ids are random and cannot be listed or guessed', async () => {
  const { upload, view, device } = env();
  const { token } = device();
  const ids = new Set<string>();
  for (let i = 0; i < 20; i++) ids.add(/\/d\/(.+)\.png$/.exec((await (await upload(token, png())).json()).url)![1]);
  assert.equal(ids.size, 20);
  const chars = new Set([...ids].join(''));
  assert.ok(chars.size > 30, 'ids use the whole base64url alphabet, not a counter');
  const one = [...ids][0];
  for (const path of ['/d/', '/d', '/v1/drawings', `/d/${one}`, `/d/${one.slice(0, -1)}A.png`, `/d/${one}.png.json`, `/d/..%2F${one}.png`]) {
    const res = await view(path);
    assert.ok([401, 404].includes(res.status), `${path}: ${res.status}`);
  }
});

test('share: uploads are rate limited per user', async () => {
  const { upload, device } = env();
  const a = device(), b = device();
  for (let i = 0; i < config.rateLimit.shareUpload.limit; i++) assert.equal((await upload(a.token, png())).status, 200);
  assert.equal((await upload(a.token, png())).status, 429);
  assert.equal((await upload(b.token, png())).status, 200);
});

test('share: other /v1 bodies keep the small limit', async () => {
  const { call, device } = setup();
  const { token } = device();
  assert.equal((await call(token, 'POST', '/v1/explain', { text: 'x'.repeat(config.bodyLimitBytes) })).status, 413);
});
