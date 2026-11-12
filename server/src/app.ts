import { Hono, type Context, type MiddlewareHandler } from 'hono';
import { bodyLimit } from 'hono/body-limit';
import { cors } from 'hono/cors';
import { secureHeaders } from 'hono/secure-headers';
import { z } from 'zod';
import { config, TONES } from './config.ts';
import { randomToken, sha256, type Cipher } from './crypto.ts';
import type { Db } from './db.ts';
import type { Ai, DeviceAction } from './ai.ts';
import { log } from './log.ts';
import { clean } from './text.ts';
import { deviceSignal, deviceTitle, deviceTrigger, lastSentence, nameIn } from './quick.ts';
import { getConnInfo } from '@hono/node-server/conninfo';
import { createAppleVerifier, type AppleVerifier } from './apple.ts';

export type Deps = {
  db: Db; cipher: Cipher; ai: Ai; now?: () => number;
  apple?: AppleVerifier;
  /** Runs once for each new user (device or Sign in with Apple). */
  onNewUser?: (userId: string) => void;
};
export type Env = { Variables: { userId: string } };
export type Chip = { kind: string; label: string; payload: Record<string, unknown>; needs_confirm: boolean; trigger?: string };

class HttpError extends Error {
  status: 400 | 401 | 404 | 409 | 428 | 429;
  constructor(status: HttpError['status'], message: string) {
    super(message);
    this.status = status;
  }
}

function createLimiter({ limit, windowMs }: { limit: number; windowMs: number }) {
  const hits = new Map<string, { n: number; reset: number }>();
  const entry = (key: string) => {
    const now = Date.now();
    let h = hits.get(key);
    if (!h || h.reset <= now) {
      if (hits.size > 10_000) hits.clear();
      h = { n: 0, reset: now + windowMs };
      hits.set(key, h);
    }
    return h;
  };
  return {
    over: (key: string) => entry(key).n >= limit,
    hit: (key: string) => ++entry(key).n > limit,
    retryAfter: (key: string) => String(Math.max(1, Math.ceil((entry(key).reset - Date.now()) / 1000))),
  };
}

function rateLimiter(bucket: keyof typeof config.rateLimit, keyOf: (c: Context<Env>) => string): MiddlewareHandler<Env> {
  const limiter = createLimiter(config.rateLimit[bucket]);
  return async (c, next) => {
    const key = keyOf(c);
    if (limiter.hit(key)) {
      c.header('Retry-After', limiter.retryAfter(key));
      return c.json({ error: 'rate limited' }, 429);
    }
    await next();
  };
}

function clientIp(c: Context<Env>): string {
  if (config.trustProxy && config.clientIpHeader) {
    const ip = c.req.header(config.clientIpHeader)?.trim();
    if (ip) return ip;
  }
  if (config.trustProxy) {
    const hops = (c.req.header('x-forwarded-for') ?? '').split(',').map((h) => h.trim()).filter(Boolean);
    if (hops.length) return hops[hops.length - 1];
  }
  try {
    return getConnInfo(c).remote.address ?? 'direct';
  } catch {
    return 'direct';
  }
}

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
const OptionalWriteText = z.string().transform(clean).pipe(z.string().max(config.maxWriteChars)).optional();
const ToneBody = z.object({ text: OptionalWriteText, context: OptionalWriteText }).strict()
  .refine((b) => b.text || b.context, { message: 'text or context is required' });
// Explain: a short question or topic the phone's regex already called an explain request. Never stored or logged.
const ExplainText = CleanText(config.maxExplainChars);
const ExplainBody = z.object({ text: ExplainText }).strict();
const VisualBody = z.object({ topic: ExplainText }).strict();
const AppleAuthBody = z.object({ identity_token: z.string().min(20).max(4096), nonce: z.string().min(16).max(128) }).strict();
const DeviceAuthBody = z.object({ device_id: z.string().uuid() }).strict();

export function createApp(deps: Deps) {
  const { db, cipher, ai } = deps;
  const now = deps.now ?? Date.now;
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

  app.use('*', secureHeaders());
  app.use('*', cors({ origin: (origin) => (config.corsOrigins.includes(origin) ? origin : null), allowMethods: ['GET', 'POST', 'PUT', 'DELETE'] }));
  app.use('/v1/*', bodyLimit({ maxSize: config.bodyLimitBytes, onError: (c) => c.json({ error: 'body too large' }, 413) }));

  app.onError((err, c) => {
    if (err instanceof z.ZodError) return c.json({ error: 'invalid request', issues: err.issues.map((i) => `${i.path.join('.') || 'body'}: ${i.message}`) }, 400);
    if (err instanceof HttpError) return c.json({ error: err.message }, err.status);
    log('error', { path: c.req.path, err: (err as Error).message });
    return c.json({ error: 'internal error' }, 500);
  });

  app.get('/health', (c) => c.json({ ok: true }));

  // ---- Sign in with Apple: the one /v1 route with no device token. It sits before the token check on purpose.
  // Every failure is a plain 401, so a caller learns nothing about which check failed.
  const verifyApple = deps.apple ?? createAppleVerifier({ now });
  app.post('/v1/auth/apple', rateLimiter('auth', clientIp), async (c) => {
    let sub: string;
    try {
      const b = AppleAuthBody.parse(await c.req.json());
      sub = (await verifyApple(b.identity_token, b.nonce)).sub;
    } catch (e) {
      log('apple_auth_rejected', { reason: e instanceof z.ZodError ? 'bad body' : (e as Error).message });
      return c.json({ error: 'unauthorized' }, 401);
    }
    const { userId, created } = db.userForAppleSub(cipher.lookupHash('apple-sub', sub));
    const token = randomToken('pkd');
    db.addDevice(userId, sha256(token), 'apple');
    if (created) deps.onNewUser?.(userId);
    log('apple_auth', { user_id: userId, created });
    return c.json({ device_token: token });
  });

  // ---- device account: the app's "Get started". No sign-in; it sits before the token check on purpose.
  // Every call makes a new user. device_id is never looked up, so nobody gets another user's token by sending their id.
  app.post('/v1/auth/device', rateLimiter('deviceAuth', clientIp), async (c) => {
    if (!DeviceAuthBody.safeParse(await c.req.json().catch(() => null)).success) return c.json({ error: 'device_id must be a UUID' }, 400);
    const userId = db.createUser();
    const token = randomToken('pkd');
    db.addDevice(userId, sha256(token), 'device');
    deps.onNewUser?.(userId);
    log('device_auth', { user_id: userId });
    return c.json({ device_token: token });
  });

  // ---- auth: every other /v1 route resolves the user from the device token, never from the body
  app.use('/v1/*', async (c, next) => {
    const m = /^Bearer (pkd_[A-Za-z0-9_-]{20,100})$/.exec(c.req.header('authorization') ?? '');
    const userId = m ? db.userForTokenHash(sha256(m[1])) : undefined;
    if (!userId) return c.json({ error: 'unauthorized' }, 401);
    c.set('userId', userId);
    await next();
  });
  const byUser = (c: Context<Env>) => c.get('userId');
  app.use('/v1/suggest', rateLimiter('suggest', byUser));
  app.use('/v1/write/*', rateLimiter('write', byUser));
  // One pattern covers /v1/explain and /v1/explain/visual, so both share the same buckets.
  app.use('/v1/explain/*', rateLimiter('explain', byUser), rateLimiter('explainDaily', byUser));
  app.use('/v1/*', rateLimiter('other', byUser));

  // ---- "Save your details": attaches an Apple account to the signed-in device account. The Apple token is checked exactly as in /v1/auth/apple.
  // If that Apple account already has a user (an earlier install), the caller gets a token for that user, so a re-install gets its data back.
  app.post('/v1/auth/apple/link', rateLimiter('auth', byUser), async (c) => {
    const userId = c.get('userId');
    let sub: string;
    try {
      const b = AppleAuthBody.parse(await c.req.json());
      sub = (await verifyApple(b.identity_token, b.nonce)).sub;
    } catch (e) {
      log('apple_link_rejected', { user_id: userId, reason: e instanceof z.ZodError ? 'bad body' : (e as Error).message });
      return c.json({ error: 'unauthorized' }, 401);
    }
    const linked = db.linkAppleSub(userId, cipher.lookupHash('apple-sub', sub));
    if (!linked) return c.json({ error: 'this account is already saved with another Apple account' }, 409);
    if (linked.owner === userId) {
      log('apple_link', { user_id: userId, recovered: false });
      return c.json({ linked: true, recovered: false });
    }
    const token = randomToken('pkd');
    db.addDevice(linked.owner, sha256(token), 'apple');
    log('apple_link', { user_id: linked.owner, recovered: true, from_user_id: userId });
    return c.json({ linked: true, recovered: true, device_token: token });
  });

  // A signed-in check with no side effects: the Debug pairing path uses it to test a token.
  app.get('/v1/me', (c) => c.json({ ok: true }));

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
  app.post('/v1/write/tone', async (c) => {
    const b = await body(c, ToneBody);
    const draft = b.text ?? '', client = b.context ?? '';
    // jev judges the tone; the LLM writes a calm reply only when the tone is not ok.
    return writing(c, 'tone', draft.length + client.length, () => ai.toneCheck(draft, client), (out) => (out.tone === 'ok' ? 1 : 2));
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

  return app;
}
