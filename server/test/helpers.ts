process.env.LOG_SILENT = '1';
import { randomBytes } from 'node:crypto';
import { createApp } from '../src/app.ts';
import type { AppleVerifier } from '../src/apple.ts';
import type { Ai, DeviceAction, ToneCheck } from '../src/ai.ts';
import { ExplanationSchema, SceneSchema } from '../src/explain.ts';
import { createCipher, randomToken, sha256 } from '../src/crypto.ts';
import type { Mail } from '../src/mailer.ts';
import { openDb } from '../src/db.ts';
import logExplain from './fixtures/log-explain.json' with { type: 'json' };
import logScene from './fixtures/log-scene.json' with { type: 'json' };
import ratesUsd from './fixtures/rates-usd.json' with { type: 'json' };
import { createRates } from '../src/rates.ts';
import type { PayDeps } from '../src/pay/routes.ts';

export const sleep = (ms = 0) => new Promise((r) => setTimeout(r, ms));

export function setup(opts: { device?: { kind?: DeviceAction; confidence?: number } | Error; write?: string | Error; tone?: ToneCheck; explain?: unknown; visual?: unknown; now?: () => number; apple?: AppleVerifier; onNewUser?: (userId: string) => void; emailEnabled?: boolean; rates?: unknown; rewriteMs?: Partial<Record<string, number>>; ai?: Ai; pay?: PayDeps } = {}) {
  const db = openDb(':memory:', { now: opts.now });
  const cipher = createCipher(randomBytes(32));
  const aiCalls: { fn: string; args: unknown[] }[] = [];
  // Each option is read once per call, so the fake server's one-shot getters answer one call each.
  const rewrite = (text: string) => {
    const w = opts.write;
    if (w instanceof Error) throw w;
    return w ?? text;
  };
  // rewriteMs: how long the model takes for one version ('fix' or a tone). Infinity stalls until the call is aborted.
  const slow = (version: string, signal?: AbortSignal) => {
    const ms = opts.rewriteMs?.[version];
    if (ms === undefined) return;
    return new Promise<void>((resolve, reject) => {
      const t = Number.isFinite(ms) ? setTimeout(resolve, ms) : undefined;
      signal?.addEventListener('abort', () => { clearTimeout(t); reject(new Error('aborted')); });
    });
  };
  const model = (v: unknown, fallback: unknown) => {
    if (v instanceof Error) throw v;
    return v ?? fallback;
  };
  const ai: Ai = opts.ai ?? {
    async deviceAction(text) {
      aiCalls.push({ fn: 'deviceAction', args: [text] });
      const d = opts.device;
      if (d instanceof Error) throw d;
      return { kind: 'none', confidence: 0.92, ...d };
    },
    async fix(text, signal) { aiCalls.push({ fn: 'fix', args: [text] }); await slow('fix', signal); return rewrite(text); },
    async refine(text, tone, signal) { aiCalls.push({ fn: 'refine', args: [text, tone] }); await slow(tone, signal); return rewrite(text); },
    async toneCheck(...args) { aiCalls.push({ fn: 'toneCheck', args }); return opts.tone ?? { tone: 'ok', calm: null }; },
    // explain and visual take the model's raw JSON (an Error to fail) and pass it through the real schemas, as createAi does.
    async explain(...args) { aiCalls.push({ fn: 'explain', args }); return ExplanationSchema.parse(model(opts.explain, logExplain)); },
    async visual(...args) { aiCalls.push({ fn: 'visual', args }); return SceneSchema.parse(model(opts.visual, logScene)); },
  };
  // Mail the server would send. Tests read codes from here; nothing leaves the process, so email sign-up works by default.
  const mails: Mail[] = [];
  const mailer = { async send(m: Mail) { mails.push(m); } };
  // The rates source answers from a fixture (or `rates`: raw source JSON, or an Error to fail). No network.
  const rateFetches: string[] = [];
  const ratesFetch = (async (url: string) => {
    rateFetches.push(String(url));
    const v = model(opts.rates, ratesUsd);
    return new Response(JSON.stringify(v), { status: 200, headers: { 'Content-Type': 'application/json' } });
  }) as typeof fetch;
  const rates = createRates({ fetch: ratesFetch, now: opts.now });
  const app = createApp({ db, cipher, ai, rates, now: opts.now, apple: opts.apple, onNewUser: opts.onNewUser, mailer, emailEnabled: opts.emailEnabled ?? true, pay: opts.pay });
  /** A signed-in user with a live access token, made straight in the DB. */
  const device = () => {
    const userId = db.createUser();
    const token = randomToken('pat');
    db.addAccessToken(db.createSession(userId, 'test'), sha256(token), (opts.now ?? Date.now)() + 400 * 86_400_000);
    return { userId, token };
  };
  /** The user behind an access token, or undefined when it no longer works. */
  const whoIs = (token: string) => db.accessFor(sha256(token))?.userId;
  /** The last code mailed to `to` for `kind`. */
  const codeFor = (to: string, kind: Mail['kind']) => mails.filter((m) => m.to === to && m.kind === kind).at(-1)?.code;
  const call = (token: string | null, method: string, path: string, body?: unknown, headers: Record<string, string> = {}) =>
    app.request(path, {
      method,
      headers: {
        'Content-Type': 'application/json',
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
        ...(path.startsWith('/v1/write') ? { 'X-User-Action': 'tap' } : {}),
        ...headers,
      },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
  return { db, cipher, app, aiCalls, device, call, mails, whoIs, codeFor, rateFetches };
}
