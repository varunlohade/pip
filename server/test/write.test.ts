import { test } from 'node:test';
import assert from 'node:assert/strict';
import { ToneSchema, rewriteSchema } from '../src/ai.ts';
import { config } from '../src/config.ts';
import { setup } from './helpers.ts';

const tap = { 'X-User-Action': 'tap' };

test('write: no token is 401, no tap header is 428, and the model is not called', async () => {
  const { call, device, aiCalls } = setup();
  const { token } = device();
  for (const path of ['/v1/write/fix', '/v1/write/refine', '/v1/write/tone']) {
    assert.equal((await call(null, 'POST', path, { text: 'hi there' })).status, 401);
    assert.equal((await call(token, 'POST', path, { text: 'hi there' }, { 'X-User-Action': '' })).status, 428);
  }
  assert.equal(aiCalls.length, 0);
});

test('write/fix: returns the fixed text and says if it changed; the model gets cleaned text', async () => {
  const { call, device, aiCalls } = setup({ write: 'I can do Tuesday at 3.' });
  const { token } = device();
  const res = await call(token, 'POST', '/v1/write/fix', { text: '  i can do\ntuesday​ at 3 ' });
  assert.equal(res.status, 200);
  const out = await res.json();
  assert.equal(out.text, 'I can do Tuesday at 3.');
  assert.equal(out.changed, true);
  assert.deepEqual(aiCalls, [{ fn: 'fix', args: ['i can do tuesday at 3'] }]);

  const same = setup();
  const d = same.device();
  assert.equal((await (await same.call(d.token, 'POST', '/v1/write/fix', { text: 'All good.' })).json()).changed, false);
});

test('write: validation and size caps', async () => {
  const { call, device, aiCalls } = setup();
  const { token } = device();
  const bad: [string, unknown][] = [
    ['/v1/write/fix', {}],
    ['/v1/write/fix', { text: '   ' }],
    ['/v1/write/fix', { text: 'x'.repeat(config.maxWriteChars + 1) }],
    ['/v1/write/fix', { text: 'ok', extra: 1 }],
    ['/v1/write/refine', { text: 'pay me' }],
    ['/v1/write/refine', { text: 'pay me', tone: 'flirty' }],
    ['/v1/write/tone', {}],
    ['/v1/write/tone', { text: '', context: ' ' }],
    ['/v1/write/tone', { context: 'x'.repeat(config.maxWriteChars + 1) }],
  ];
  for (const [path, body] of bad) assert.equal((await call(token, 'POST', path, body)).status, 400, `${path} ${JSON.stringify(body).slice(0, 40)}`);
  assert.equal((await call(token, 'POST', '/v1/write/fix', { text: 'x'.repeat(config.bodyLimitBytes) })).status, 413);
  assert.equal(aiCalls.length, 0);
  assert.equal((await call(token, 'POST', '/v1/write/fix', { text: 'x'.repeat(config.maxWriteChars) })).status, 200);
});

test('write/refine: every tone reaches the model; the answer comes back', async () => {
  const { call, device, aiCalls } = setup({ write: 'Could you pay by Friday, please?' });
  const { token } = device();
  for (const tone of ['polite', 'professional', 'friendly', 'shorter', 'firmer']) {
    const res = await call(token, 'POST', '/v1/write/refine', { text: 'pay me by friday', tone });
    assert.equal(res.status, 200);
    assert.equal((await res.json()).text, 'Could you pay by Friday, please?');
  }
  assert.deepEqual(aiCalls.map((c) => c.args[1]), ['polite', 'professional', 'friendly', 'shorter', 'firmer']);
});

test('write/tone: draft, copied client message, or both', async () => {
  const calm = 'I am sorry about the wait. I will make it right.';
  const { call, device, aiCalls } = setup({ tone: { tone: 'upset', calm } });
  const { token } = device();
  const res = await call(token, 'POST', '/v1/write/tone', { context: 'This is the WORST service ever!!' });
  assert.equal(res.status, 200);
  const out = await res.json();
  assert.deepEqual([out.tone, out.calm], ['upset', calm]);
  assert.equal((await call(token, 'POST', '/v1/write/tone', { text: 'Pay now.', context: 'Why so late?' })).status, 200);
  assert.deepEqual(aiCalls.map((c) => c.args), [['', 'This is the WORST service ever!!'], ['Pay now.', 'Why so late?']]);
});

test('write: a model failure is a 502 with no detail', async () => {
  const { call, device } = setup({ write: new Error('Unexpected token in "secret client text"') });
  const { token } = device();
  const res = await call(token, 'POST', '/v1/write/fix', { text: 'secret client text' });
  assert.equal(res.status, 502);
  assert.ok(!(await res.text()).includes('secret'));
});

test('write: rate limit per user', async () => {
  const { call, device } = setup();
  const a = device(), b = device();
  let last = 0;
  for (let i = 0; i <= config.rateLimit.write.limit; i++) last = (await call(a.token, 'POST', '/v1/write/fix', { text: 'hello' })).status;
  assert.equal(last, 429);
  assert.equal((await call(b.token, 'POST', '/v1/write/fix', { text: 'hello' })).status, 200);
});

test('write: nothing from the text reaches the log', async (t) => {
  const { call, device } = setup({ write: new Error('boom TOPSECRET') });
  const { token } = device();
  const lines: string[] = [];
  t.mock.method(console, 'log', (l: string) => { lines.push(l); });
  process.env.LOG_SILENT = '0';
  try {
    await call(token, 'POST', '/v1/write/fix', { text: 'TOPSECRET draft' });
    await call(token, 'POST', '/v1/write/tone', { context: 'TOPSECRET client' });
  } finally {
    process.env.LOG_SILENT = '1';
  }
  assert.ok(lines.some((l) => l.includes('"event":"write"')));
  assert.ok(!lines.join('\n').includes('TOPSECRET'));
});

test('write output schemas: size guard, cleaning, tone values', () => {
  const input = 'i can do tuesday at 3';
  assert.equal(rewriteSchema(input).parse({ text: ' I can do\nTuesday at 3. ' }).text, 'I can do Tuesday at 3.');
  assert.throws(() => rewriteSchema(input).parse({ text: 'x'.repeat(400) }));
  assert.throws(() => rewriteSchema(input).parse({ text: '' }));
  assert.throws(() => rewriteSchema(input).parse({ answer: 'hi' }));
  assert.deepEqual(ToneSchema.parse({ tone: 'blunt', calm: 'Could you pay today?' }), { tone: 'blunt', calm: 'Could you pay today?' });
  assert.deepEqual(ToneSchema.parse({ tone: 'ok', calm: 'ignored' }), { tone: 'ok', calm: null });
  assert.deepEqual(ToneSchema.parse({ tone: 'upset', calm: null }), { tone: 'ok', calm: null });
  assert.throws(() => ToneSchema.parse({ tone: 'flirty', calm: 'hey' }));
});
