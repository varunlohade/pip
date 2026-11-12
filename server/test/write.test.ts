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

/** Reads an NDJSON reply line by line, with the time each line arrived. */
async function lines(res: Response) {
  const t0 = performance.now();
  const out: { at: number; line: any }[] = [];
  const reader = res.body!.pipeThrough(new TextDecoderStream()).getReader();
  let buf = '';
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    buf += value;
    let i;
    while ((i = buf.indexOf('\n')) >= 0) {
      out.push({ at: performance.now() - t0, line: JSON.parse(buf.slice(0, i)) });
      buf = buf.slice(i + 1);
    }
  }
  return out;
}

test('write/rewrite: streams every version as it is ready; a slow one comes last and does not hold the others', async () => {
  const { call, device, aiCalls } = setup({ write: 'Could you pay by Friday, please?', rewriteMs: { polite: 900, shorter: 10 } });
  const { token } = device();
  const res = await call(token, 'POST', '/v1/write/rewrite', { text: 'pay me by friday' });
  assert.equal(res.status, 200);
  assert.match(res.headers.get('content-type') ?? '', /ndjson/);
  const got = await lines(res);
  const versions = got.filter((g) => g.line.tone);
  assert.deepEqual(versions.map((g) => g.line.tone).sort(), ['firmer', 'fix', 'friendly', 'polite', 'professional', 'shorter']);
  assert.ok(versions.every((g) => g.line.text === 'Could you pay by Friday, please?'));
  assert.equal(versions.at(-1)!.line.tone, 'polite', 'the slow version comes last');
  assert.ok(versions[0].at < 450, `first version after ${versions[0].at} ms`);
  assert.ok(versions.at(-1)!.at >= 850, 'the slow one really waited');
  assert.equal(got.at(-1)!.line.done, true);
  assert.equal(aiCalls.length, 6, 'one model call per version');
});

test('write/rewrite: a stalled version is skipped after the stall limit; the rest still arrive', async () => {
  const before = config.llm.rewriteStallMs;
  config.llm.rewriteStallMs = 200;
  try {
    const { call, device } = setup({ rewriteMs: { fix: Infinity } });
    const { token } = device();
    const t = performance.now();
    const got = await lines(await call(token, 'POST', '/v1/write/rewrite', { text: 'pay me by friday' }));
    const ms = performance.now() - t;
    const fix = got.find((g) => g.line.tone === 'fix')!;
    assert.deepEqual(fix.line, { tone: 'fix', error: 'stalled' });
    assert.ok(fix.at >= 190 && fix.at < 1800, `stall skipped after ${fix.at} ms`);
    assert.equal(got.filter((g) => g.line.text).length, 5);
    assert.equal(got.at(-1)!.line.done, true);
    assert.ok(ms < 2400, `whole reply took ${ms} ms`);
  } finally {
    config.llm.rewriteStallMs = before;
  }
});

test('write/rewrite: Retry asks only the named versions; bad tones, no tap and model errors behave', async () => {
  const { call, device, aiCalls } = setup();
  const { token } = device();
  const got = await lines(await call(token, 'POST', '/v1/write/rewrite', { text: 'pay me by friday', tones: ['fix', 'polite'] }));
  assert.deepEqual(got.filter((g) => g.line.tone).map((g) => g.line.tone).sort(), ['fix', 'polite']);
  assert.equal(aiCalls.length, 2);
  for (const b of [{ text: 'hi', tones: [] }, { text: 'hi', tones: ['flirty'] }, { text: '  ' }, { text: 'hi', tone: 'polite' }]) {
    assert.equal((await call(token, 'POST', '/v1/write/rewrite', b)).status, 400, JSON.stringify(b));
  }
  assert.equal((await call(token, 'POST', '/v1/write/rewrite', { text: 'hi' }, { 'X-User-Action': '' })).status, 428);
  const bad = setup({ write: new Error('boom "secret client text"') });
  const d = bad.device();
  const res = await bad.call(d.token, 'POST', '/v1/write/rewrite', { text: 'secret client text', tones: ['shorter'] });
  const body = await res.text();
  assert.ok(!body.includes('secret'));
  assert.deepEqual(body.trim().split('\n').map((l) => JSON.parse(l)).filter((l) => l.tone), [{ tone: 'shorter', error: 'failed' }]);
});

test('write/rewrite: has its own limit per user, since one rewrite starts a model call per version', async () => {
  const { call, device, aiCalls } = setup();
  const a = device(), b = device();
  for (let i = 0; i < config.rateLimit.rewrite.limit; i++) {
    assert.equal((await call(a.token, 'POST', '/v1/write/rewrite', { text: 'pay me by friday' })).status, 200, `rewrite ${i + 1}`);
  }
  const calls = aiCalls.length;
  const over = await call(a.token, 'POST', '/v1/write/rewrite', { text: 'pay me by friday', tones: ['fix'] });
  assert.equal(over.status, 429);
  assert.ok(Number(over.headers.get('retry-after')) >= 1);
  assert.equal(aiCalls.length, calls, 'a limited rewrite starts no model call');
  assert.equal((await call(a.token, 'POST', '/v1/write/fix', { text: 'pay me' })).status, 200, 'fix still works');
  assert.equal((await call(b.token, 'POST', '/v1/write/rewrite', { text: 'pay me by friday' })).status, 200, 'another user is not limited');
});
