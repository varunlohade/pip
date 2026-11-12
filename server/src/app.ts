import { Hono, type Context } from 'hono';
import { bodyLimit } from 'hono/body-limit';
import { cors } from 'hono/cors';
import { secureHeaders } from 'hono/secure-headers';
import { z } from 'zod';
import { config, REWRITES, TONES, type Rewrite } from './config.ts';
import { stream } from 'hono/streaming';
import type { Cipher } from './crypto.ts';
import { randomBytes } from 'node:crypto';
import type { Db, Preview, SharedImage } from './db.ts';
import { isPng, jpegSize, pngSize } from './image.ts';
import type { Ai, DeviceAction } from './ai.ts';
import { log } from './log.ts';
import { clean } from './text.ts';
import { deviceSignal, deviceTitle, deviceTrigger, lastSentence, nameIn } from './quick.ts';
import { createAppleVerifier, type AppleVerifier } from './apple.ts';
import { createAuth } from './auth.ts';
import { PasswordBusyError } from './password.ts';
import { clientIp, HttpError, rateLimiter, type Env } from './http.ts';
import { createDevMailer, type Mailer } from './mailer.ts';
import { createRates, type Rates } from './rates.ts';

export type Deps = {
  db: Db; cipher: Cipher; ai: Ai; now?: () => number;
  apple?: AppleVerifier;
  /** Sends emailed codes. The default only logs (see mailer.ts); no real email goes out yet. */
  mailer?: Mailer;
  /** GET /v1/auth/config reports it. Default false: the app hides email sign-in. */
  emailEnabled?: boolean;
  /** Runs once for each new user (device, Apple or email). */
  onNewUser?: (userId: string) => void;
  /** Currency rates for the keyboard's conversions. The default reads the keyless public source, cached for an hour. */
  rates?: Rates;
};
export type { Env };
export type Chip = { kind: string; label: string; payload: Record<string, unknown>; needs_confirm: boolean; trigger?: string };

const CleanText = (max: number) => z.string().transform(clean).pipe(z.string().min(1).max(max));
// context: text the user copied from the other person. Cleaned and capped.
const SuggestBody = z.object({
  text: z.string().trim().max(config.maxTextChars),
  context: z.string().transform((v) => clean(v).slice(0, config.maxContextChars)).optional(),
}).strict().refine((b) => b.text || b.context, { message: 'text or context is required' });
// Writing help: one paragraph, cleaned and capped. The text is never stored or logged.
const WriteText = CleanText(config.maxWriteChars);
const FixBody = z.object({ text: WriteText }).strict();
const RefineBody = z.object({ text: WriteText, tone: z.enum(TONES) }).strict();
// The rewrite list: every version by default, or the ones the phone retries.
const RewriteBody = z.object({ text: WriteText, tones: z.array(z.enum(REWRITES)).min(1).max(REWRITES.length).optional() }).strict();
const OptionalWriteText = z.string().transform(clean).pipe(z.string().max(config.maxWriteChars)).optional();
const ToneBody = z.object({ text: OptionalWriteText, context: OptionalWriteText }).strict()
  .refine((b) => b.text || b.context, { message: 'text or context is required' });
// Explain: a short question or topic the phone's regex already called an explain request. Never stored or logged.
const ExplainText = CleanText(config.maxExplainChars);
const ExplainBody = z.object({ text: ExplainText }).strict();
const VisualBody = z.object({ topic: ExplainText }).strict();

const esc = (s: string) => s.replace(/[&<>"']/g, (ch) => `&#${ch.charCodeAt(0)};`);

const PAGE_STYLE = 'body{margin:0;background:#f4f8fc;font:16px -apple-system,system-ui,sans-serif;color:#1c2b3a}' +
  'main{max-width:960px;margin:0 auto;padding:16px}img{display:block;width:100%;height:auto;border-radius:16px;background:#fff}' +
  'h1{font-size:18px;font-weight:600;margin:4px 0 12px}p{color:#5b6b7b;margin:12px 0 0;font-size:14px}';

/** The share page: Open Graph and Twitter tags so iMessage, WhatsApp, Telegram and Slack show the picture, and the drawing full width. */
function sharePage(base: string, id: string, img: SharedImage): string {
  const title = img.title ?? 'A drawing from Pip';
  const page = `${base}/d/${id}`;
  const full = pngSize(img.png);
  const og = img.preview
    ? { url: `${page}.jpg`, type: 'image/jpeg', width: img.preview.width, height: img.preview.height }
    : { url: `${page}.png`, type: 'image/png', width: full?.width, height: full?.height };
  const meta = (attr: 'property' | 'name', key: string, value: string | number | undefined) =>
    value === undefined ? '' : `<meta ${attr}="${key}" content="${esc(String(value))}">`;
  return '<!doctype html><html lang="en"><head><meta charset="utf-8">' +
    '<meta name="viewport" content="width=device-width,initial-scale=1">' +
    `<title>${esc(title)}</title>` +
    meta('property', 'og:type', 'website') + meta('property', 'og:site_name', 'Pip') +
    meta('property', 'og:title', title) + meta('property', 'og:description', 'Made with Pip') +
    meta('property', 'og:url', page) + meta('property', 'og:image', og.url) + meta('property', 'og:image:type', og.type) +
    meta('property', 'og:image:width', og.width) + meta('property', 'og:image:height', og.height) +
    meta('property', 'og:image:alt', title) +
    meta('name', 'twitter:card', 'summary_large_image') + meta('name', 'twitter:title', title) +
    meta('name', 'twitter:description', 'Made with Pip') + meta('name', 'twitter:image', og.url) +
    `<meta name="robots" content="noindex"><style>${PAGE_STYLE}</style></head><body><main>` +
    `<h1>${esc(title)}</h1><img src="${esc(page)}.png" alt="${esc(title)}"${full ? ` width="${full.width}" height="${full.height}"` : ''}>` +
    '<p>Made with Pip</p></main></body></html>';
}

const gonePage = '<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">' +
  `<title>This drawing has expired</title><meta name="robots" content="noindex"><style>${PAGE_STYLE}</style></head>` +
  '<body><main><h1>This drawing has expired</h1><p>Pip keeps shared drawings for 30 days.</p></main></body></html>';

export function createApp(deps: Deps) {
  const { db, cipher, ai } = deps;
  const now = deps.now ?? Date.now;
  const rates = deps.rates ?? createRates({ now });
  const app = new Hono<Env>();

  const body = async <T extends z.ZodTypeAny>(c: Context<Env>, schema: T): Promise<z.infer<T>> => {
    let raw: unknown;
    try {
      raw = await c.req.json();
    } catch {
      throw new HttpError(400, 'body must be JSON');
    }
    return schema.parse(raw);
  };

  // A shared drawing's images may be loaded from any origin (chat apps show the preview); everything else stays same-origin.
  const secure = secureHeaders(), secureShared = secureHeaders({ crossOriginResourcePolicy: 'cross-origin' });
  app.use('*', (c, next) => (/^\/d\/[^/]+\.(png|jpg)$/.test(c.req.path) ? secureShared(c, next) : secure(c, next)));
  app.use('*', cors({ origin: (origin) => (config.corsOrigins.includes(origin) ? origin : null), allowMethods: ['GET', 'POST', 'PUT', 'DELETE'] }));
  const smallBody = bodyLimit({ maxSize: config.bodyLimitBytes, onError: (c) => c.json({ error: 'body too large' }, 413) });
  // Every /v1 body is small JSON, except a drawing (PNG plus its JPEG preview) sent to share as a link, which gets its own cap.
  app.use('/v1/*', (c, next) => (c.req.path === '/v1/drawings' ? next() : smallBody(c, next)));
  app.use('/v1/drawings', bodyLimit({ maxSize: config.sharedImage.maxBytes + config.sharedImage.preview.maxBytes + 16 * 1024, onError: (c) => c.json({ error: 'image too large' }, 413) }));

  app.onError((err, c) => {
    if (err instanceof z.ZodError) return c.json({ error: 'invalid request', issues: err.issues.map((i) => `${i.path.join('.') || 'body'}: ${i.message}`) }, 400);
    if (err instanceof HttpError) return c.json({ error: err.message }, err.status);
    if (err instanceof PasswordBusyError) {
      log('password_busy', { path: c.req.path });
      c.header('Retry-After', '5');
      return c.json({ error: 'busy, try again in a few seconds' }, 503);
    }
    log('error', { path: c.req.path, err: (err as Error).message });
    return c.json({ error: 'internal error' }, 500);
  });

  app.get('/health', (c) => c.json({ ok: true }));

  // ---- a shared drawing. No token: whoever has the link sees the drawing and nothing else.
  // /d/<id> is a small page whose Open Graph tags make chats show the picture; /d/<id>.png is the drawing, /d/<id>.jpg the preview.
  // An unknown id is a plain 404; an expired one is 410 with no image.
  app.get('/d/:file', rateLimiter('shareView', clientIp), (c) => {
    const m = /^([A-Za-z0-9_-]{22})(\.png|\.jpg)?$/.exec(c.req.param('file'));
    const at = now();
    const img = m ? db.sharedImage(m[1], at) : undefined;
    c.header('X-Robots-Tag', 'noindex, nofollow');
    if (!m || !img || (m[2] === '.jpg' && img !== 'gone' && !img.preview)) return c.text('not found', 404);
    if (img === 'gone') {
      c.header('Cache-Control', 'public, max-age=86400');
      c.header('Content-Security-Policy', "default-src 'none'");
      return m[2] ? c.text('this drawing has expired', 410) : c.html(gonePage, 410);
    }
    // Never cached past the link's own end, so an expired link is not served from a cache.
    const left = Math.max(0, Math.floor((img.expiresAt - at) / 1000));
    if (!m[2]) {
      c.header('Cache-Control', `public, max-age=${Math.min(3600, left)}`);
      c.header('Content-Security-Policy', "default-src 'none'; img-src 'self'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'");
      return c.html(sharePage(config.publicUrl || new URL(c.req.url).origin, m[1], img));
    }
    const [bytes, type] = m[2] === '.png' ? [img.png, 'image/png'] : [img.preview!.jpeg, 'image/jpeg'];
    return c.body(new Uint8Array(bytes), 200, {
      'Content-Type': type,
      'Cache-Control': `public, max-age=${Math.min(86400, left)}`,
      'Content-Security-Policy': "default-src 'none'",
      'X-Content-Type-Options': 'nosniff',
    });
  });

  // ---- sign-in, sessions and the account. Routes with no token sit before the token check on purpose.
  // Every other /v1 route resolves the user from the access token, never from the body.
  const auth = createAuth({ db, cipher, now, mailer: deps.mailer ?? createDevMailer(), emailEnabled: deps.emailEnabled ?? false, apple: deps.apple ?? createAppleVerifier({ now }), onNewUser: deps.onNewUser });
  auth.publicRoutes(app);
  auth.requireUser(app);
  const byUser = (c: Context<Env>) => c.get('userId');
  app.use('/v1/suggest', rateLimiter('suggest', byUser));
  app.use('/v1/write/*', rateLimiter('write', byUser));
  app.use('/v1/write/rewrite', rateLimiter('rewrite', byUser));
  // One pattern covers /v1/explain and /v1/explain/visual, so both share the same buckets.
  app.use('/v1/explain/*', rateLimiter('explain', byUser), rateLimiter('explainDaily', byUser));
  app.use('/v1/*', rateLimiter('other', byUser));
  auth.privateRoutes(app);

  // ---- suggest
  // Regex first: plain chat ends with no paid call. An action-ish sentence gets one jev question, and the
  // phone does the work (calendar, reminders, notes).
  app.post('/v1/suggest', async (c) => {
    const userId = c.get('userId');
    const { text, context } = await body(c, SuggestBody);
    const t0 = performance.now();
    const timings: Record<string, number> = {};
    let path = 'regex_none';
    const done = (chips: Chip[], intent: string, confidence: number) => {
      timings.total_ms = Math.round(performance.now() - t0);
      const paid_calls = path === 'regex_none' ? 0 : 1;
      log('suggest', { user_id: userId, path, paid_calls, intent, confidence, chips: chips.length, ...timings });
      return c.json({ chips, intent, confidence, timings });
    };
    if (context || !deviceSignal(text)) return done([], 'none', 1);
    path = 'jev_device';
    const sentence = lastSentence(text);
    let picked;
    try {
      picked = await ai.deviceAction(sentence);
    } catch (e) {
      log('device_failed', { err: (e as Error).message });
      return done([], 'error', 0);
    }
    if (picked.kind === 'none' || picked.confidence < config.jev.minConfidence) return done([], 'none', picked.confidence);
    return done(deviceChips(picked.kind, sentence), picked.kind, picked.confidence);
  });

  /**
   * A device chip runs on the phone (calendar, reminders, notes), never here. The server gives the kind and a title;
   * the phone fills the time from its own reading of the sentence, or tomorrow 9 AM for a follow-up.
   */
  function deviceChips(kind: Exclude<DeviceAction, 'none'>, sentence: string): Chip[] {
    const title = deviceTitle(sentence);
    if (!title) return [];
    const name = nameIn(sentence);
    const base = { needs_confirm: false, trigger: deviceTrigger(sentence) };
    switch (kind) {
      case 'event': return [{ kind, label: 'Add to calendar', payload: { title }, ...base }];
      case 'reminder': return [{ kind, label: 'Remind me', payload: { title }, ...base }];
      case 'note': return [{ kind, label: 'Save note', payload: { text: sentence }, ...base }];
      case 'followup': return [{ kind, label: 'Follow up', payload: { title: name ? `Follow up with ${name}` : `Follow up: ${title}` }, ...base }];
    }
  }

  // ---- writing help: runs only from a tap in the keyboard. Only sizes and timings are logged, never the text.
  app.use('/v1/write/*', async (c, next) => {
    if (c.req.header('x-user-action') !== 'tap') return c.json({ error: 'writing help runs only from an explicit user tap' }, 428);
    await next();
  });
  const writing = async <T extends object>(c: Context<Env>, kind: string, chars: number, run: () => Promise<T>, paid: (out: T) => number = () => 1) => {
    const t = performance.now();
    try {
      const out = await run();
      const ms = Math.round(performance.now() - t);
      log('write', { user_id: c.get('userId'), kind, chars, ms, ok: true, paid_calls: paid(out) });
      return c.json({ ...out, ms });
    } catch (e) {
      // A model error can quote the text, so only its type is logged.
      log('write', { user_id: c.get('userId'), kind, chars, ms: Math.round(performance.now() - t), ok: false, err: (e as Error).name });
      return c.json({ error: 'writing help is not available right now' }, 502);
    }
  };
  app.post('/v1/write/fix', async (c) => {
    const { text } = await body(c, FixBody);
    return writing(c, 'fix', text.length, async () => {
      const fixed = await ai.fix(text);
      return { text: fixed, changed: fixed !== text };
    });
  });
  app.post('/v1/write/refine', async (c) => {
    const { text, tone } = await body(c, RefineBody);
    return writing(c, `refine_${tone}`, text.length, async () => ({ text: await ai.refine(text, tone) }));
  });
  // All versions at once, one JSON line each (NDJSON) the moment it is ready, then {"done":true}.
  // A version with no answer after rewriteStallMs is skipped as {"tone","error":"stalled"}; the phone offers Retry for it.
  app.post('/v1/write/rewrite', async (c) => {
    const { text, tones } = await body(c, RewriteBody);
    const wanted = [...new Set(tones ?? REWRITES)];
    const userId = c.get('userId');
    const t0 = performance.now();
    c.header('Content-Type', 'application/x-ndjson; charset=utf-8');
    c.header('Cache-Control', 'no-store');
    return stream(c, async (s) => {
      const gone = new AbortController();
      s.onAbort(() => gone.abort());
      const one = async (tone: Rewrite) => {
        const stop = new AbortController();
        const signal = AbortSignal.any([stop.signal, gone.signal]);
        let timer: ReturnType<typeof setTimeout> | undefined;
        const stalled = new Promise<never>((_, reject) => {
          timer = setTimeout(() => { stop.abort(); reject(new Error('stalled')); }, config.llm.rewriteStallMs);
        });
        const t = performance.now();
        let line: { tone: Rewrite; text?: string; error?: 'stalled' | 'failed' };
        try {
          line = { tone, text: await Promise.race([tone === 'fix' ? ai.fix(text, signal) : ai.refine(text, tone, signal), stalled]) };
        } catch (e) {
          line = { tone, error: stop.signal.aborted ? 'stalled' : 'failed' };
          // A model error can quote the text, so only its type is logged.
          if (!stop.signal.aborted) log('write_error', { err: (e as Error).name });
        } finally {
          clearTimeout(timer);
        }
        log('write', { user_id: userId, kind: `rewrite_${tone}`, chars: text.length, ms: Math.round(performance.now() - t), ok: !line.error, paid_calls: 1 });
        if (!gone.signal.aborted) await s.write(JSON.stringify(line) + '\n');
      };
      await Promise.all(wanted.map(one));
      if (!gone.signal.aborted) await s.write(JSON.stringify({ done: true, ms: Math.round(performance.now() - t0) }) + '\n');
    });
  });
  app.post('/v1/write/tone', async (c) => {
    const b = await body(c, ToneBody);
    const draft = b.text ?? '', client = b.context ?? '';
    // jev judges the tone; the LLM writes a calm reply only when the tone is not ok.
    return writing(c, 'tone', draft.length + client.length, () => ai.toneCheck(draft, client), (out) => (out.tone === 'ok' ? 1 : 2));
  });

  // ---- "Send as link": the keyboard uploads a drawing and types the short link into the chat.
  // multipart/form-data with `image` (the PNG), `preview` (a JPEG for link previews) and an optional `title`;
  // a bare image/png body (older builds) is still taken, with no preview.
  app.post('/v1/drawings', rateLimiter('shareUpload', byUser), async (c) => {
    const lim = config.sharedImage;
    let png: Uint8Array, previewBytes: Uint8Array | undefined, title: string | undefined;
    const type = c.req.header('content-type') ?? '';
    if (type === 'image/png') {
      png = new Uint8Array(await c.req.arrayBuffer());
    } else if (type.startsWith('multipart/form-data')) {
      const form = await c.req.parseBody().catch(() => undefined);
      const image = form?.image, preview = form?.preview;
      if (!(image instanceof File) || !(preview instanceof File)) return c.json({ error: 'send image and preview files' }, 400);
      png = new Uint8Array(await image.arrayBuffer());
      previewBytes = new Uint8Array(await preview.arrayBuffer());
      title = typeof form?.title === 'string' ? clean(form.title).slice(0, lim.maxTitleChars) || undefined : undefined;
    } else {
      return c.json({ error: 'send a PNG image' }, 400);
    }
    if (!isPng(png)) return c.json({ error: 'send a PNG image' }, 400);
    if (png.length > lim.maxBytes) return c.json({ error: 'image too large' }, 413);
    let preview: Preview | undefined;
    if (previewBytes) {
      if (previewBytes.length > lim.preview.maxBytes) return c.json({ error: 'preview too large' }, 413);
      const size = jpegSize(previewBytes);
      if (!size) return c.json({ error: 'preview must be a JPEG' }, 400);
      if (size.width < lim.preview.minWidth || size.width > lim.preview.maxSide || size.height > lim.preview.maxSide) {
        return c.json({ error: `preview must be ${lim.preview.minWidth} to ${lim.preview.maxSide} px wide` }, 400);
      }
      preview = { jpeg: previewBytes, ...size };
    }
    const at = now();
    db.purgeSharedImages(at, lim.keepGoneMs);
    // 128 random bits: the link cannot be guessed, and ids say nothing about the user or the time.
    const id = randomBytes(16).toString('base64url');
    const expiresAt = at + lim.ttlMs;
    db.addSharedImage({ id, userId: c.get('userId'), png, createdAt: at, expiresAt, preview, title });
    log('share_image', { user_id: c.get('userId'), bytes: png.length, preview_bytes: preview?.jpeg.length ?? 0 });
    const base = config.publicUrl || new URL(c.req.url).origin;
    return c.json({ url: `${base}/d/${id}`, image_url: `${base}/d/${id}.png`, expires_at: new Date(expiresAt).toISOString() });
  });

  // ---- explain: the phone sends only text its own regex read as an explain request, so plain chat never reaches here.
  // Only sizes and timings are logged, never the question or the answer.
  const explaining = async <T extends object>(c: Context<Env>, kind: string, chars: number, run: () => Promise<T>) => {
    const t = performance.now();
    try {
      const out = await run();
      log('explain', { user_id: c.get('userId'), kind, chars, ms: Math.round(performance.now() - t), ok: true, paid_calls: 1 });
      return c.json(out);
    } catch (e) {
      log('explain', { user_id: c.get('userId'), kind, chars, ms: Math.round(performance.now() - t), ok: false, err: (e as Error).name });
      return c.json({ error: 'explain is not available right now' }, 502);
    }
  };
  app.post('/v1/explain', async (c) => {
    const { text } = await body(c, ExplainBody);
    return explaining(c, 'explain', text.length, () => ai.explain(text));
  });
  app.post('/v1/explain/visual', async (c) => {
    const { topic } = await body(c, VisualBody);
    return explaining(c, 'visual', topic.length, () => ai.visual(topic));
  });

  // ---- rates: the phone keeps the last answer, so currency sums work offline.
  app.get('/v1/rates', async (c) => {
    try {
      return c.json(await rates.get());
    } catch {
      return c.json({ error: 'rates are not available right now' }, 502);
    }
  });

  return app;
}
