// A local stand-in Pip server for the iOS app and UI tests: fake AI, in-memory DB, no network.
// usage: npm run fake   (PORT=0 picks a free port; the first line printed names it)
// Debug routes: GET /_log, GET /_mail (the stub mail, with codes, for sign-up tests), POST /_reset, POST /_next {"device": {"kind", "confidence"}, "write": "text", "tone": {"tone", "calm"}, "explain": {...}, "visual": {...}}
// explain and visual take raw model JSON; with none, they answer with the log-function fixtures in test/fixtures.
// Each /_next value answers the next matching model call once.
// Pay runs the phone-signed flow on a fake NEAR testnet and mainnet in memory (ana/bob .testnet and .near exist; mainnet is on,
// with no network); the phone's real signature is checked. AI replies say they ran in an attested TEE.
import { serve } from '@hono/node-server';
import { Hono } from 'hono';
import type { DeviceAction, ToneCheck } from '../src/ai.ts';
import { config } from '../src/config.ts';
import { randomToken, sha256 } from '../src/crypto.ts';
import type { AttestationSnapshot } from '../src/nearai.ts';
import { SignedTransaction } from 'near-api-js';
import type { Chain } from '../src/pay/chain.ts';
import { payConfig } from '../src/pay/config.ts';
import { mainnetConfig } from '../src/pay/network.ts';
import type { PhoneChain } from '../src/pay/phone/chain.ts';
import { toUnits } from '../src/pay/parse.ts';
import { setup } from '../test/helpers.ts';

if (process.env.NODE_ENV === 'production') {
  console.error('fake server refuses to start with NODE_ENV=production');
  process.exit(1);
}
globalThis.fetch = async () => {
  throw new Error('the fake server makes no network calls');
};

const FAKE_TOKEN = 'pkd_fake';
// The server only accepts long access tokens, so the short public token is swapped for this one on the way in.
const INNER_TOKEN = 'pat_fake_local_only_access_token';
// UI tests sign up and start over many times from one address.
for (const k of ['deviceAuth', 'auth', 'emailAuth', 'mailPerEmail'] as const) config.rateLimit[k].limit = 1000;

type Next = { device?: { kind?: DeviceAction; confidence?: number }; write?: string; tone?: ToneCheck; explain?: unknown; visual?: unknown };
type LogEntry = { method: string; path: string; status: number; body: unknown };

/** A NEAR testnet stand-in: two known accounts, fixed balances that go down with each send, no network. */
function fakeChain(): Chain {
  const accounts = new Set(['ana.testnet', 'bob.testnet']);
  let usdc = toUnits('42.1', 'USDC'), near = toUnits('4.85', 'NEAR'), n = 0;
  return {
    async accountExists(id) { return accounts.has(id); },
    async balances() { return { NEAR: near, USDC: usdc }; },
    newKey() { return { publicKey: 'ed25519:fakepub', secretKey: 'ed25519:fakesecret' }; },
    async createAccount(id) { accounts.add(id); return 'fakecreate'; },
    async prepareSend(_from, token, _to, units) {
      n++;
      return {
        hash: `7Hq2Xb9TfE3mNwq8RkLz5VdYc1pA6sGh${n}uJkP4`,
        async broadcast() {
          if (token === 'USDC') usdc -= units; else near -= units;
          return 'ok';
        },
      };
    },
  };
}

/** One NEAR network for the phone-signed flow: fixed accounts, balances that go down with each signed send, no network. */
function fakePhoneChain(suffix: string): PhoneChain {
  const accounts = new Set([`ana${suffix}`, `bob${suffix}`]);
  let usdc = toUnits('42.1', 'USDC'), near = toUnits('4.85', 'NEAR');
  return {
    async accountExists(id) { return accounts.has(id); },
    async accessKeyNonce() { return 1000n; },
    async recentBlockHash() { return 'GJ8ThW5tGmvBbGr8Kto6Ahtv1mhK5cXhkRMdNsJxbVkK'; },
    async storageRegistered() { return true; },
    async storageMin() { return 1_250_000_000_000_000_000_000n; },
    async balances() { return { NEAR: near, USDC: usdc }; },
    async broadcast(signed) {
      for (const a of SignedTransaction.decode(Buffer.from(signed)).transaction.actions) {
        if (a.transfer) near -= BigInt(a.transfer.deposit);
        if (a.functionCall?.methodName === 'ft_transfer') usdc -= BigInt(JSON.parse(Buffer.from(a.functionCall.args).toString()).amount);
      }
      return 'ok';
    },
    async fund() { return 'FakeFundTx'; },
  };
}

const attestation: AttestationSnapshot = {
  provider: 'near-ai', tier: 'Confidential TEE (NEAR-run)', verify_url: 'https://cloud.near.ai/verify',
  models: [{ model: 'deepseek-ai/DeepSeek-V3.1', ok: true, checked_at: '2026-11-14T16:00:00.000Z', nonce: '00'.repeat(32), gateway: { ok: true, signing_address: '0xfake' }, model_reports: [{ ok: true, signing_address: '0xfake' }] }],
  last_signature: { model: 'deepseek-ai/DeepSeek-V3.1', chat_id: 'chatcmpl-fake', ok: true, kind: 'ecdsa', signer: '0xfake', checked_at: '2026-11-14T16:00:00.000Z' },
  method: ['Fresh 32-byte nonce per check (fake server: fixed values)', 'Intel TDX quote checked to the Intel root (fake server: not run)'],
  not_checked: ['Intel TCB status and revocation lists', 'NVIDIA GPU evidence', 'An allowlist of the measured app and OS hashes', "Pip's server sees your text before it reaches the TEE"],
};

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
    pay: {
      chain: fakeChain(),
      config: { ...payConfig, funderAccountId: 'pipfund.testnet', funderSecretKey: 'ed25519:fake' },
      phone: { chains: { testnet: fakePhoneChain('.testnet'), mainnet: fakePhoneChain('.near') }, mainnet: { ...mainnetConfig, enabled: true } },
    },
    served: { model: 'deepseek-ai/DeepSeek-V3.1', private: true, attested: true },
    attestation,
  });
  const userId = env.db.createUser();
  // A session that lasts a year, with a refresh token so the purge keeps it.
  const year = Date.now() + 365 * 86_400_000;
  const session = env.db.createSession(userId, 'fake');
  env.db.addAccessToken(session, sha256(INNER_TOKEN), year);
  env.db.addRefreshToken(session, sha256(randomToken('prt')), year);
  return { ...env, next, log: [] as LogEntry[], userId };
}

let state = build();
const fake = new Hono();

fake.get('/_log', (c) => c.json({ requests: state.log, ai: state.aiCalls }));
fake.get('/_mail', (c) => c.json({ mails: state.mails }));
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
