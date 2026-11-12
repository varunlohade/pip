// A local stand-in Pip server for the iOS app and UI tests: fake AI, in-memory DB, no network.
// usage: npm run fake   (PORT=0 picks a free port; the first line printed names it)
// Debug routes: GET /_log, POST /_reset, POST /_next {"device": {"kind", "confidence"}, "write": "text", "tone": {"tone", "calm"}, "explain": {...}, "visual": {...}}
// explain and visual take raw model JSON; with none, they answer with the log-function fixtures in test/fixtures.
// Each /_next value answers the next matching model call once.
import { serve } from '@hono/node-server';
import { Hono } from 'hono';
import type { DeviceAction, ToneCheck } from '../src/ai.ts';
import { config } from '../src/config.ts';
import { sha256 } from '../src/crypto.ts';
import { setup } from '../test/helpers.ts';

if (process.env.NODE_ENV === 'production') {
  console.error('fake server refuses to start with NODE_ENV=production');
  process.exit(1);
}
globalThis.fetch = async () => {
  throw new Error('the fake server makes no network calls');
};

const FAKE_TOKEN = 'pkd_fake';
// The app only accepts long pkd_ tokens, so the short public token is swapped for this one on the way in.
const INNER_TOKEN = 'pkd_fake_local_only_device_token';

type Next = { device?: { kind?: DeviceAction; confidence?: number }; write?: string; tone?: ToneCheck; explain?: unknown; visual?: unknown };
type LogEntry = { method: string; path: string; status: number; body: unknown };

function build() {
  const next: Next = {};
  const take = <K extends keyof Next>(k: K): Next[K] => {
    const v = next[k];
    delete next[k];
    return v;
  };
  const env = setup({
    get device() { return take('device'); },
    get write() { return take('write'); },
    get tone() { return take('tone'); },
    get explain() { return take('explain'); },
    get visual() { return take('visual'); },
    apple: async () => { throw new Error('no Sign in with Apple on the fake server'); },
  });
  const userId = env.db.createUser();
  env.db.addDevice(userId, sha256(INNER_TOKEN), 'fake');
  return { ...env, next, log: [] as LogEntry[], userId };
}

let state = build();
const fake = new Hono();

fake.get('/_log', (c) => c.json({ requests: state.log, ai: state.aiCalls }));
fake.post('/_reset', (c) => {
  state = build();
  return c.json({ ok: true });
});
fake.post('/_next', async (c) => {
  const b = (await c.req.json().catch(() => ({}))) as Next;
  if (b.device) state.next.device = b.device;
  if (b.write !== undefined) state.next.write = b.write;
  if (b.tone) state.next.tone = b.tone;
  if (b.explain) state.next.explain = b.explain;
  if (b.visual) state.next.visual = b.visual;
  return c.json({ ok: true, next: state.next });
});

// "Get started" in the app: the fake signs every device in as the one seeded user.
fake.post('/v1/auth/device', (c) => c.json({ device_token: INNER_TOKEN }));

fake.all('*', async (c) => {
  const req = c.req.raw;
  const headers = new Headers(req.headers);
  if (headers.get('authorization') === `Bearer ${FAKE_TOKEN}`) headers.set('authorization', `Bearer ${INNER_TOKEN}`);
  // Bytes, not text: a drawing PNG must reach the app unchanged.
  const raw = ['GET', 'HEAD'].includes(req.method) ? new Uint8Array() : new Uint8Array(await req.arrayBuffer());
  const res = await state.app.fetch(new Request(req.url, { method: req.method, headers, body: raw.length ? raw : undefined }));
  const json = (headers.get('content-type') ?? '').includes('json');
  let body: unknown = raw.length ? (json ? new TextDecoder().decode(raw) : `<${raw.length} bytes>`) : null;
  try {
    if (json && raw.length) body = JSON.parse(body as string);
  } catch {}
  state.log.push({ method: req.method, path: new URL(req.url).pathname, status: res.status, body });
  return res;
});

serve({ fetch: fake.fetch, port: config.port, hostname: '127.0.0.1' }, (info) => {
  console.log(`fake pip on http://127.0.0.1:${info.port}  token ${FAKE_TOKEN}`);
});
