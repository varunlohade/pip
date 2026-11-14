import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createAi } from '../src/ai.ts';
import { config } from '../src/config.ts';
import { addressOf, checkReport, keccak256, recoverEip191 } from '../src/nearai.ts';
import { setup } from './helpers.ts';
import fx from './fixtures/near-attestation.json' with { type: 'json' };

// fixtures/near-attestation.json: a real report from GET cloud-api.near.ai/v1/attestation/report for z-ai/glm-5.3-flash,
// fetched 2026-11-14 with the nonce stored beside it (GPU evidence and unused fields trimmed).
const report = (fx as any).report;
const NOW = Date.parse('2026-11-14T16:10:00Z');
const NEAR = new URL(config.nearai.url).host;
const clone = <T>(v: T): T => structuredClone(v);

test('keccak-256 and EIP-191 recovery match known Ethereum vectors', () => {
  assert.equal(keccak256(Buffer.alloc(0)).toString('hex'), 'c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470');
  // personal_sign("hello world") by the well-known Hardhat test account #0.
  const sig = '0xa461f509887bd19e312c0c58467ce8ff8e300d3c1a90b608a760c5b80318eaf15fe57c96f9175d6cd4daad4663763baa7e78836e067d0163e9a2ccf2ff753f5b1b';
  assert.equal(recoverEip191('hello world', sig), '0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266');
  assert.notEqual(recoverEip191('hello world!', sig), '0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266');
  const model = report.model_attestations[0];
  assert.equal(addressOf(Buffer.from(model.signing_public_key, 'hex')), model.signing_address);
});

test('checkReport: the real gateway and model reports pass every check', () => {
  assert.deepEqual(checkReport(report.gateway_attestation, fx.nonce, NOW), { ok: true, signing_address: report.gateway_attestation.signing_address });
  assert.deepEqual(checkReport(report.model_attestations[0], fx.nonce, NOW), { ok: true, signing_address: report.model_attestations[0].signing_address });
});

test('checkReport: a wrong nonce, signer, config, event or quote byte fails', () => {
  const m = report.model_attestations[0];
  const other = 'ab'.repeat(32);
  assert.match(checkReport(m, other, NOW).failure!, /nonce/);
  assert.match(checkReport({ ...m, request_nonce: other }, other, NOW).failure!, /signer and nonce/);
  assert.match(checkReport({ ...m, signing_address: '0x' + '11'.repeat(20) }, fx.nonce, NOW).failure!, /signer and nonce/);
  const info = clone(m.info);
  info.tcb_info.app_compose += ' ';
  assert.match(checkReport({ ...m, info }, fx.nonce, NOW).failure!, /app_compose/);
  const events = clone(m.event_log);
  const i = events.findIndex((e: any) => e.imr === 3);
  events[i] = { ...events[i], event_payload: '00', digest: '' };
  assert.match(checkReport({ ...m, event_log: events }, fx.nonce, NOW).failure!, /RTMR3/);
  const q = Buffer.from(m.intel_quote, 'hex');
  q[600] ^= 1;
  assert.match(checkReport({ ...m, intel_quote: q.toString('hex') }, fx.nonce, NOW).failure!, /quote signature/);
  assert.match(checkReport(m, fx.nonce, Date.parse('2060-01-01')).failure!, /out of date/);
});

type Hit = { host: string; path: string; body?: any; headers: Record<string, string> };
/** A fake NEAR AI Cloud and OpenRouter. `near` answers per model: a reply text, or a status code to fail. */
function fakeCloud(opts: { near?: Record<string, string | number>; signature?: unknown } = {}) {
  const hits: Hit[] = [];
  const fetch = (async (input: string | URL, init: RequestInit = {}) => {
    const url = new URL(String(input));
    const body = init.body ? JSON.parse(String(init.body)) : undefined;
    hits.push({ host: url.host, path: url.pathname, body, headers: Object.fromEntries(new Headers(init.headers).entries()) });
    const json = (v: unknown, status = 200) => new Response(JSON.stringify(v), { status });
    if (url.pathname.endsWith('/attestation/report')) {
      // Serve the real report for the model it covers; other models get a report with no model candidates.
      return url.searchParams.get('model') === fx.model ? json(report) : json({ gateway_attestation: report.gateway_attestation });
    }
    if (url.pathname.includes('/signature/')) return opts.signature ? json(opts.signature) : json({}, 404);
    const reply = url.host === NEAR ? opts.near?.[body.model] ?? 500 : 'Hello from OpenRouter.';
    if (typeof reply === 'number') return json({ error: 'down' }, reply);
    return json({ id: `chatcmpl-${hits.length}`, choices: [{ message: { content: JSON.stringify({ text: reply }) } }] });
  }) as typeof globalThis.fetch;
  return { hits, fetch };
}

test('NEAR key set: replies come from a NEAR TEE model with no OpenRouter fields, marked private and attested', async () => {
  const cloud = fakeCloud({ near: { [config.nearai.primary]: 503, [fx.model]: 'Hello, how are you?' } });
  const ai = createAi({ typesafeKey: 'k', openrouterKey: 'or', nearaiKey: 'near', fetch: cloud.fetch, nonce: () => fx.nonce });
  const { call, device } = setup({ ai });
  assert.equal((await call(null, 'GET', '/v1/ai/attestation')).status, 401, 'the proof screen needs a signed-in user');
  const { token } = device();
  const proof = await (await call(token, 'GET', '/v1/ai/attestation')).json();
  assert.equal(proof.provider, 'near-ai');
  assert.deepEqual(proof.models.map((m: any) => [m.model, m.ok]), [[config.nearai.primary, false], [fx.model, true]]);
  assert.equal(proof.models[0].failure, 'no model report');
  assert.ok(proof.not_checked.length > 0);

  const res = await call(token, 'POST', '/v1/write/fix', { text: 'hello how r u' });
  assert.equal(res.status, 200);
  const out = await res.json();
  assert.equal(out.text, 'Hello, how are you?');
  assert.deepEqual([out.private, out.attested, out.model], [true, true, fx.model]);
  const chats = cloud.hits.filter((h) => h.path.endsWith('/chat/completions'));
  assert.ok(chats.every((h) => h.host === NEAR), 'OpenRouter is not called while NEAR answers');
  assert.ok(chats.every((h) => h.body.provider === undefined && h.headers['x-no-aliasing'] === 'true' && h.headers.authorization === 'Bearer near'));
  assert.deepEqual(chats.find((h) => h.body.model === fx.model)!.body.response_format, { type: 'json_object' });
});

test('NEAR model with no passing attestation: private but not attested', async () => {
  const cloud = fakeCloud({ near: { [config.nearai.primary]: 'Hi there.' } });
  const ai = createAi({ typesafeKey: 'k', nearaiKey: 'near', fetch: cloud.fetch, nonce: () => fx.nonce });
  await ai.attestation!();
  const { call, device } = setup({ ai });
  const out = await (await call(device().token, 'POST', '/v1/explain', { text: 'what is a vpn' })).json();
  // explain wants a different JSON shape, so this reply fails its schema and every model fails: no false green.
  assert.equal(out.error, 'explain is not available right now');
  const fix = await (await call(device().token, 'POST', '/v1/write/fix', { text: 'hi ther' })).json();
  assert.deepEqual([fix.text, fix.private, fix.attested, fix.model], ['Hi there.', true, false, config.nearai.primary]);
});

test('NEAR down: falls back to OpenRouter and says the reply is not private', async () => {
  const cloud = fakeCloud({ near: {} });
  const ai = createAi({ typesafeKey: 'k', openrouterKey: 'or', nearaiKey: 'near', fetch: cloud.fetch, nonce: () => fx.nonce });
  const orig = globalThis.fetch;
  globalThis.fetch = cloud.fetch; // the OpenRouter path uses the global fetch
  try {
    const { call, device } = setup({ ai });
    const out = await (await call(device().token, 'POST', '/v1/write/fix', { text: 'hello from openrouter' })).json();
    assert.deepEqual([out.text, out.private, out.attested, out.model], ['Hello from OpenRouter.', false, false, config.llm.primary.model]);
    const chats = cloud.hits.filter((h) => h.path.endsWith('/chat/completions')).map((h) => h.host);
    assert.deepEqual(chats.slice(0, 2), [NEAR, NEAR]);
    assert.ok(chats.slice(2).every((h) => h === 'openrouter.ai'));
  } finally {
    globalThis.fetch = orig;
  }
});

test('no NEAR key: OpenRouter only, no NEAR calls, and the proof screen says not private', async (t) => {
  const cloud = fakeCloud();
  t.mock.method(globalThis, 'fetch', cloud.fetch);
  const ai = createAi({ typesafeKey: 'k', openrouterKey: 'or' });
  const { call, device } = setup({ ai });
  const { token } = device();
  const out = await (await call(token, 'POST', '/v1/write/fix', { text: 'hello from openrouter' })).json();
  assert.deepEqual([out.private, out.attested, out.model], [false, false, config.llm.primary.model]);
  assert.deepEqual(await (await call(token, 'GET', '/v1/ai/attestation')).json(), { provider: 'openrouter', private: false, attested: false });
  assert.ok(cloud.hits.every((h) => h.host !== NEAR));
  assert.throws(() => createAi({ typesafeKey: 'k' }), /NEARAI_API_KEY or OPENROUTER_API_KEY/);
});

test('reply signature: a signature over other bytes is recorded as failed, never as verified', async () => {
  const cloud = fakeCloud({
    near: { [config.nearai.primary]: 503, [fx.model]: 'Hello.' },
    signature: { text: 'not:these:bytes', signature: '0x' + '00'.repeat(65), signing_address: report.model_attestations[0].signing_address, signing_algo: 'ecdsa', signature_kind: 'provider_tee' },
  });
  const ai = createAi({ typesafeKey: 'k', nearaiKey: 'near', fetch: cloud.fetch, nonce: () => fx.nonce });
  await ai.attestation!();
  const { call, device } = setup({ ai });
  const { token } = device();
  await call(token, 'POST', '/v1/write/fix', { text: 'hello' });
  let sig = null;
  for (let i = 0; i < 50 && !sig; i++) {
    await new Promise((r) => setTimeout(r, 10));
    sig = (await (await call(token, 'GET', '/v1/ai/attestation')).json()).last_signature;
  }
  assert.equal(sig.ok, false);
  assert.equal(sig.failure, 'signed text does not match these bytes');
  const sigHit = cloud.hits.find((h) => h.path.includes('/signature/'))!;
  assert.equal(sigHit.headers.authorization, 'Bearer near');
});
