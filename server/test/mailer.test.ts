process.env.LOG_SILENT = '1';
import { test, type TestContext } from 'node:test';
import assert from 'node:assert/strict';
import { createMailer, createResendMailer } from '../src/mailer.ts';

const ADDRESS = 'ana.secret@example.com';
const CODE = '483920';
const ENV = { RESEND_API_KEY: 're_test_key', MAIL_FROM: 'Pip <hello@pip.test>' };

type Call = { url: string; init: RequestInit };
function fakeFetch(reply: () => Promise<Response>) {
  const calls: Call[] = [];
  const f = (async (url: string, init: RequestInit) => { calls.push({ url, init }); return reply(); }) as unknown as typeof fetch;
  return { f, calls };
}

/** Runs fn with logging on and returns every console.log line. */
async function captureLogs(t: TestContext, fn: () => Promise<unknown>) {
  const lines: string[] = [];
  t.mock.method(console, 'log', (...a: unknown[]) => { lines.push(a.map(String).join(' ')); });
  process.env.LOG_SILENT = '0';
  try {
    await fn();
  } finally {
    process.env.LOG_SILENT = '1';
  }
  return lines;
}

test('resend: posts a plain-text code email with the key, and resolves on 200', async () => {
  const { f, calls } = fakeFetch(async () => new Response('{"id":"x"}', { status: 200 }));
  await createMailer(ENV, f).send({ to: ADDRESS, kind: 'verify', code: CODE });
  assert.equal(calls.length, 1);
  assert.equal(calls[0].url, 'https://api.resend.com/emails');
  assert.equal(calls[0].init.method, 'POST');
  assert.equal((calls[0].init.headers as Record<string, string>).authorization, 'Bearer re_test_key');
  assert.ok(calls[0].init.signal instanceof AbortSignal);
  const body = JSON.parse(calls[0].init.body as string);
  assert.equal(body.from, ENV.MAIL_FROM);
  assert.deepEqual(body.to, [ADDRESS]);
  assert.match(body.text, /^Your Pip code is 483920\. It expires in 15 minutes\./);
  assert.equal(body.html, undefined);
});

test('resend: the reset email carries the reset code', async () => {
  const { f, calls } = fakeFetch(async () => new Response('{}', { status: 200 }));
  await createMailer(ENV, f).send({ to: ADDRESS, kind: 'reset', code: CODE });
  assert.match(JSON.parse(calls[0].init.body as string).text, /^Your Pip reset code is 483920\. It expires in 15 minutes\./);
});

for (const status of [422, 500]) {
  test(`resend: a ${status} reply rejects`, async () => {
    const { f } = fakeFetch(async () => new Response(`{"message":"bad ${ADDRESS}"}`, { status }));
    await assert.rejects(createMailer(ENV, f).send({ to: ADDRESS, kind: 'verify', code: CODE }), { name: 'MailSendError' });
  });
}

test('resend: a reply slower than the timeout rejects', async () => {
  const hang = ((_url: string, init: RequestInit) => new Promise<Response>((_, reject) => {
    init.signal!.addEventListener('abort', () => reject(init.signal!.reason));
  })) as unknown as typeof fetch;
  const mailer = createResendMailer({ apiKey: 'k', from: 'f@pip.test', fetch: hang, timeoutMs: 20 });
  await assert.rejects(mailer.send({ to: ADDRESS, kind: 'verify', code: CODE }), { name: 'TimeoutError' });
});

test('mailer: no key keeps the dev stub and never calls fetch', async (t) => {
  const { f, calls } = fakeFetch(async () => new Response('{}', { status: 200 }));
  const lines = await captureLogs(t, () => createMailer({ MAIL_FROM: ENV.MAIL_FROM }, f).send({ to: ADDRESS, kind: 'verify', code: CODE }));
  assert.equal(calls.length, 0);
  assert.ok(lines.some((l) => l.includes('"event":"mail_stub"')));
});

test('mailer: a key without MAIL_FROM stops startup', () => {
  assert.throws(() => createMailer({ RESEND_API_KEY: 'k' }), /MAIL_FROM/);
});

test('mailer: no address or code reaches the log, on success or failure', async (t) => {
  const ok = fakeFetch(async () => new Response('{}', { status: 200 }));
  const bad = fakeFetch(async () => new Response(`{"message":"bad ${ADDRESS} ${CODE}"}`, { status: 500 }));
  const lines = await captureLogs(t, async () => {
    await createMailer(ENV, ok.f).send({ to: ADDRESS, kind: 'verify', code: CODE });
    await createMailer(ENV, bad.f).send({ to: ADDRESS, kind: 'reset', code: CODE }).catch(() => {});
    await createMailer({}, ok.f).send({ to: ADDRESS, kind: 'link', code: CODE });
  });
  assert.ok(lines.some((l) => l.includes('"event":"mail_sent"')));
  assert.ok(lines.some((l) => l.includes('"event":"mail_rejected"') && l.includes('500')));
  const all = lines.join('\n');
  assert.ok(!all.includes(ADDRESS) && !all.includes('ana.secret'));
  assert.ok(!all.includes(CODE));
});
