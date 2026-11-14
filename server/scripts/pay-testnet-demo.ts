// One live run of the whole pay path on NEAR testnet, through the real routes and an in-memory database:
// a new user gets a wallet, sets up an approver, proposes 0.01 NEAR to PAY_DEMO_TO, and approves it.
// Needs PAY_FUNDER_ACCOUNT_ID and PAY_FUNDER_PRIVATE_KEY (a .testnet account). Testnet only.
process.env.LOG_SILENT = '1';
import { randomBytes } from 'node:crypto';
import { createApp } from '../src/app.ts';
import { createCipher, randomToken, sha256 } from '../src/crypto.ts';
import { openDb } from '../src/db.ts';
import type { Ai } from '../src/ai.ts';

const to = process.env.PAY_DEMO_TO ?? process.env.PAY_FUNDER_ACCOUNT_ID ?? '';
const db = openDb(':memory:');
const app = createApp({ db, cipher: createCipher(randomBytes(32)), ai: {} as Ai });
const userId = db.createUser();
const token = randomToken('pat');
db.addAccessToken(db.createSession(userId, 'demo'), sha256(token), Date.now() + 3_600_000);
const call = async (method: string, path: string, body?: unknown, headers: Record<string, string> = {}) => {
  const r = await app.request(path, { method, headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}`, ...headers }, body: body === undefined ? undefined : JSON.stringify(body) });
  const out = await r.json();
  console.log(method, path, r.status, JSON.stringify(out).replace(/pap_[A-Za-z0-9_-]+/, 'pap_[hidden]'));
  return out as Record<string, string>;
};

await call('POST', '/v1/pay/parse', { text: `send 0.01 NEAR to ${to}` });
await call('GET', '/v1/pay/wallet');
const { approver_key } = await call('POST', '/v1/pay/approver');
const fields = { amount: '0.01', token: 'NEAR', recipient: to };
const intent = await call('POST', '/v1/pay/intents', fields);
await call('POST', `/v1/pay/intents/${intent.id}/approve`, fields, { 'X-Pay-Approver': approver_key });
await call('POST', `/v1/pay/intents/${intent.id}/approve`, fields, { 'X-Pay-Approver': approver_key });
await call('GET', '/v1/pay/wallet');
