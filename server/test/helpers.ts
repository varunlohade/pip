process.env.LOG_SILENT = '1';
import { randomBytes } from 'node:crypto';
import { createApp } from '../src/app.ts';
import type { AppleVerifier } from '../src/apple.ts';
import type { Ai, DeviceAction, ToneCheck } from '../src/ai.ts';
import { ExplanationSchema, SceneSchema } from '../src/explain.ts';
import { createCipher, randomToken, sha256 } from '../src/crypto.ts';
import { openDb } from '../src/db.ts';
import logExplain from './fixtures/log-explain.json' with { type: 'json' };
import logScene from './fixtures/log-scene.json' with { type: 'json' };

export const sleep = (ms = 0) => new Promise((r) => setTimeout(r, ms));

export function setup(opts: { device?: { kind?: DeviceAction; confidence?: number } | Error; write?: string | Error; tone?: ToneCheck; explain?: unknown; visual?: unknown; now?: () => number; apple?: AppleVerifier; onNewUser?: (userId: string) => void } = {}) {
  const db = openDb(':memory:');
  const cipher = createCipher(randomBytes(32));
  const aiCalls: { fn: string; args: unknown[] }[] = [];
  // Each option is read once per call, so the fake server's one-shot getters answer one call each.
  const rewrite = (text: string) => {
    const w = opts.write;
    if (w instanceof Error) throw w;
    return w ?? text;
  };
  const model = (v: unknown, fallback: unknown) => {
    if (v instanceof Error) throw v;
    return v ?? fallback;
  };
  const ai: Ai = {
    async deviceAction(text) {
      aiCalls.push({ fn: 'deviceAction', args: [text] });
      const d = opts.device;
      if (d instanceof Error) throw d;
      return { kind: 'none', confidence: 0.92, ...d };
    },
    async fix(...args) { aiCalls.push({ fn: 'fix', args }); return rewrite(args[0]); },
    async refine(...args) { aiCalls.push({ fn: 'refine', args }); return rewrite(args[0]); },
    async toneCheck(...args) { aiCalls.push({ fn: 'toneCheck', args }); return opts.tone ?? { tone: 'ok', calm: null }; },
    // explain and visual take the model's raw JSON (an Error to fail) and pass it through the real schemas, as createAi does.
    async explain(...args) { aiCalls.push({ fn: 'explain', args }); return ExplanationSchema.parse(model(opts.explain, logExplain)); },
    async visual(...args) { aiCalls.push({ fn: 'visual', args }); return SceneSchema.parse(model(opts.visual, logScene)); },
  };
  const app = createApp({ db, cipher, ai, now: opts.now, apple: opts.apple, onNewUser: opts.onNewUser });
  const device = () => {
    const userId = db.createUser();
    const token = randomToken('pkd');
    db.addDevice(userId, sha256(token), 'test');
    return { userId, token };
  };
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
  return { db, cipher, app, aiCalls, device, call };
}
