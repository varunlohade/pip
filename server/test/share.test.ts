import { test } from 'node:test';
import assert from 'node:assert/strict';
import { config } from '../src/config.ts';
import { jpegSize, pngSize } from '../src/image.ts';
import { setup } from './helpers.ts';

const PNG_MAGIC = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
const png = (size = 64): Uint8Array<ArrayBuffer> => {
  const b = new Uint8Array(size);
  b.set(PNG_MAGIC);
  for (let i = PNG_MAGIC.length; i < size; i++) b[i] = i % 251;
  return b;
};
/** A PNG header with a real IHDR, so the page can read its size. */
const pngOf = (width: number, height: number, size = 64): Uint8Array<ArrayBuffer> => {
  const b = png(size);
  const v = new DataView(b.buffer);
  v.setUint32(8, 13);
  b.set([0x49, 0x48, 0x44, 0x52], 12);
  v.setUint32(16, width);
  v.setUint32(20, height);
  return b;
};
/** A JPEG header (SOI, APP0, SOF0) of the given size, padded to `bytes`. */
const jpeg = (width: number, height: number, bytes = 2000): Uint8Array<ArrayBuffer> => {
  const b = new Uint8Array(bytes);
  b.set([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46, 0x00, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00]);
  b.set([0xff, 0xc0, 0x00, 0x11, 0x08, height >> 8, height & 255, width >> 8, width & 255, 0x03], 20);
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
  /** The phone's upload: the PNG, its JPEG preview and a title, as multipart/form-data. */
  const share = (token: string | null, parts: { image?: Uint8Array<ArrayBuffer>; preview?: Uint8Array<ArrayBuffer>; title?: string } = {}) => {
    const form = new FormData();
    if (parts.image) form.append('image', new Blob([parts.image], { type: 'image/png' }), 'drawing.png');
    if (parts.preview) form.append('preview', new Blob([parts.preview], { type: 'image/jpeg' }), 'preview.jpg');
    if (parts.title !== undefined) form.append('title', parts.title);
    return s.app.request('/v1/drawings', { method: 'POST', headers: token ? { Authorization: `Bearer ${token}` } : {}, body: form });
  };
  const view = (path: string, init?: RequestInit) => s.app.request(path, init);
  return { ...s, upload, share, view };
}

/** Every <meta property|name content> on the page, as a map. */
const metaTags = (html: string) => {
  const out: Record<string, string> = {};
  for (const m of html.matchAll(/<meta (?:property|name)="([^"]+)" content="([^"]*)">/g)) out[m[1]] = m[2];
  return out;
};

test('share: a bare PNG (older builds) uploads and its .png serves exactly that image, as image/png, with no user data', async () => {
  const { upload, view, device } = env();
  const { token, userId } = device();
  const image = png(300);
  const res = await upload(token, image);
  assert.equal(res.status, 200);
  const out = await res.json();
  const m = /^http:\/\/localhost\/d\/([A-Za-z0-9_-]{22})$/.exec(out.url);
  assert.ok(m, out.url);
  assert.equal(out.image_url, `${out.url}.png`);
  assert.ok(Date.parse(out.expires_at) > Date.now() + 29 * 86_400_000);
  const got = await view(new URL(out.image_url).pathname);
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

test('share: after 30 days the page and both images answer 410 with no image, and the stored images are emptied', async () => {
  let t = Date.parse('2026-11-12T10:00:00Z');
  const { share, upload, view, device, db } = env({ now: () => t });
  const { token } = device();
  const page = new URL((await (await share(token, { image: pngOf(1200, 800), preview: jpeg(900, 600), title: 'log' })).json()).url).pathname;
  t += config.sharedImage.ttlMs - 1000;
  for (const p of [page, `${page}.png`, `${page}.jpg`]) {
    const res = await view(p);
    assert.equal(res.status, 200, p);
    assert.ok(Number(/max-age=(\d+)/.exec(res.headers.get('cache-control')!)![1]) <= 1, `${p}: never cached past the end`);
  }
  t += 2000;
  for (const p of [page, `${page}.png`, `${page}.jpg`]) {
    const res = await view(p);
    assert.equal(res.status, 410, p);
    const type = res.headers.get('content-type') ?? '';
    assert.ok(!type.startsWith('image/'), `${p}: ${type}`);
    const text = await res.text();
    assert.ok(!text.includes('og:image') && !text.includes('<img'), `${p}: no image`);
  }
  await upload(token, png());
  const row = db.raw.prepare('SELECT length(png) AS png, preview, title FROM shared_images WHERE expires_at <= ?').get(t) as { png: number; preview: unknown; title: unknown };
  assert.deepEqual({ ...row }, { png: 0, preview: null, title: null }, 'the expired images are gone; the row only says it expired');
  assert.equal((await view(page)).status, 410);
  t += config.sharedImage.keepGoneMs;
  await upload(token, png());
  assert.equal((await view(page)).status, 404, 'a year later the row is deleted too');
});

test('share: ids are random and cannot be listed or guessed', async () => {
  const { upload, view, device } = env();
  const { token } = device();
  const ids = new Set<string>();
  for (let i = 0; i < 20; i++) ids.add(/\/d\/(.+)$/.exec((await (await upload(token, png())).json()).url)![1]);
  assert.equal(ids.size, 20);
  const chars = new Set([...ids].join(''));
  assert.ok(chars.size > 30, 'ids use the whole base64url alphabet, not a counter');
  const one = [...ids][0];
  const other = one.slice(0, -1) + (one.endsWith('A') ? 'B' : 'A');
  for (const path of ['/d/', '/d', '/v1/drawings', `/d/${other}`, `/d/${other}.png`, `/d/${one}.png.json`, `/d/${one}.gif`, `/d/${one}.jpg`, `/d/..%2F${one}.png`, `/d/${one}/`]) {
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

test('share: the page has Open Graph and Twitter tags that point at the JPEG preview', async () => {
  const { share, view, device } = env();
  const { token } = device();
  const res = await share(token, { image: pngOf(1600, 1000, 4000), preview: jpeg(960, 600, 50_000), title: 'y = log(x) <b>&</b>' });
  assert.equal(res.status, 200);
  const out = await res.json();
  const page = await view(new URL(out.url).pathname);
  assert.equal(page.status, 200);
  assert.equal(page.headers.get('content-type'), 'text/html; charset=UTF-8');
  assert.match(page.headers.get('cache-control')!, /^public, max-age=3600$/);
  assert.match(page.headers.get('content-security-policy')!, /default-src 'none'; img-src 'self'/);
  assert.equal(page.headers.get('x-robots-tag'), 'noindex, nofollow');
  assert.equal(page.headers.get('set-cookie'), null);
  const html = await page.text();
  const tags = metaTags(html);
  assert.equal(tags['og:type'], 'website');
  assert.equal(tags['og:title'], 'y = log(x) &#60;b&#62;&#38;&#60;/b&#62;', 'the title is escaped');
  assert.equal(tags['og:description'], 'Made with Pip');
  assert.equal(tags['og:url'], out.url);
  assert.equal(tags['og:image'], `${out.url}.jpg`);
  assert.equal(tags['og:image:type'], 'image/jpeg');
  assert.equal(tags['og:image:width'], '960');
  assert.equal(tags['og:image:height'], '600');
  assert.equal(tags['twitter:card'], 'summary_large_image');
  assert.equal(tags['twitter:image'], `${out.url}.jpg`);
  assert.ok(!html.includes('<b>'), 'no raw HTML from the title');
  assert.match(html, new RegExp(`<img src="${out.url}\\.png"[^>]* width="1600" height="1000">`), 'the page shows the full drawing');
  assert.match(html, /Made with Pip/);
  assert.ok(!html.includes('<script'), 'no script on the page');
});

test('share: the preview serves as image/jpeg and the drawing as image/png, unchanged', async () => {
  const { share, view, device } = env();
  const { token } = device();
  const image = pngOf(1200, 800, 5000), preview = jpeg(900, 600, 40_000);
  const out = await (await share(token, { image, preview, title: 'log' })).json();
  const p = new URL(out.url).pathname;
  const jpg = await view(`${p}.jpg`);
  assert.equal(jpg.status, 200);
  assert.equal(jpg.headers.get('content-type'), 'image/jpeg');
  assert.equal(jpg.headers.get('cache-control'), 'public, max-age=86400');
  assert.equal(jpg.headers.get('x-content-type-options'), 'nosniff');
  assert.equal(jpg.headers.get('cross-origin-resource-policy'), 'cross-origin');
  const jpgBytes = new Uint8Array(await jpg.arrayBuffer());
  assert.deepEqual(jpgBytes, preview);
  assert.deepEqual(jpegSize(jpgBytes), { width: 900, height: 600 });
  const full = await view(`${p}.png`);
  assert.equal(full.headers.get('content-type'), 'image/png');
  const pngBytes = new Uint8Array(await full.arrayBuffer());
  assert.deepEqual(pngBytes, image);
  assert.deepEqual(pngSize(pngBytes), { width: 1200, height: 800 });
  assert.equal((await view(`${p}.jpg`, { method: 'HEAD' })).status, 200);
});

test('share: a bad preview is refused and nothing is stored', async () => {
  const { share, device, db } = env();
  const { token } = device();
  const max = config.sharedImage.preview;
  const cases: [Parameters<typeof share>[1], number][] = [
    [{ image: png() }, 400],
    [{ preview: jpeg(900, 600) }, 400],
    [{ image: png(), preview: png() }, 400],
    [{ image: jpeg(900, 600), preview: jpeg(900, 600) }, 400],
    [{ image: png(), preview: jpeg(max.minWidth - 1, 400) }, 400],
    [{ image: png(), preview: jpeg(900, max.maxSide + 1) }, 400],
    [{ image: png(), preview: jpeg(900, 600, max.maxBytes + 1) }, 413],
    [{ image: png(config.sharedImage.maxBytes + 1), preview: jpeg(900, 600) }, 413],
  ];
  for (const [parts, status] of cases) assert.equal((await share(token, parts)).status, status, JSON.stringify(Object.keys(parts ?? {})));
  assert.equal((await share(null, { image: png(), preview: jpeg(900, 600) })).status, 401);
  assert.equal((db.raw.prepare('SELECT COUNT(*) AS n FROM shared_images').get() as { n: number }).n, 0);
  assert.equal((await share(token, { image: png(), preview: jpeg(max.minWidth, 400, max.maxBytes) })).status, 200, 'at the limits is fine');
});

test('share: with no title the page says "A drawing from Pip"; a long title is cut', async () => {
  const { share, view, device } = env();
  const { token } = device();
  const plain = await (await share(token, { image: png(), preview: jpeg(900, 600) })).json();
  assert.equal(metaTags(await (await view(new URL(plain.url).pathname)).text())['og:title'], 'A drawing from Pip');
  const long = await (await share(token, { image: png(), preview: jpeg(900, 600), title: 'x'.repeat(500) })).json();
  assert.equal(metaTags(await (await view(new URL(long.url).pathname)).text())['og:title'].length, config.sharedImage.maxTitleChars);
});

test('share: a bare PNG page falls back to the PNG as og:image', async () => {
  const { upload, view, device } = env();
  const { token } = device();
  const out = await (await upload(token, pngOf(800, 500))).json();
  const tags = metaTags(await (await view(new URL(out.url).pathname)).text());
  assert.equal(tags['og:image'], `${out.url}.png`);
  assert.equal(tags['og:image:width'], '800');
  assert.equal((await view(`${new URL(out.url).pathname}.jpg`)).status, 404, 'no preview was sent');
});

test('share: an old database gains the preview columns', async () => {
  const { DatabaseSync } = await import('node:sqlite');
  const { openDb } = await import('../src/db.ts');
  const { mkdtempSync } = await import('node:fs');
  const { join } = await import('node:path');
  const { tmpdir } = await import('node:os');
  const path = join(mkdtempSync(join(tmpdir(), 'pip-db-')), 'old.db');
  const old = new DatabaseSync(path);
  old.exec('CREATE TABLE users (id TEXT PRIMARY KEY, created_at INTEGER NOT NULL, apple_sub_hash TEXT); CREATE TABLE shared_images (id TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id), png BLOB NOT NULL, created_at INTEGER NOT NULL, expires_at INTEGER NOT NULL);');
  old.close();
  const db = openDb(path);
  const u = db.createUser();
  db.addSharedImage({ id: 'a'.repeat(22), userId: u, png: png(), createdAt: 1, expiresAt: 10, preview: { jpeg: jpeg(900, 600), width: 900, height: 600 }, title: 't' });
  const got = db.sharedImage('a'.repeat(22), 5);
  assert.ok(got && got !== 'gone' && got.preview?.width === 900 && got.title === 't');
  assert.equal(db.sharedImage('a'.repeat(22), 10), 'gone');
});
