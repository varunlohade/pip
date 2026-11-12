import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createAi } from '../src/ai.ts';
import { setup } from './helpers.ts';

test('toneCheck: jev picks the label; the LLM runs only when the tone is not ok', async (t) => {
  const hits: string[] = [];
  let label = '3';
  t.mock.method(globalThis, 'fetch', async (url: string, init: { body: string }) => {
    const host = new URL(url).host;
    hits.push(host);
    const body = host === 'api.typesafe.ai'
      ? { answers: { q: { choice: label, confidence: 0.9 } } }
      : { choices: [{ message: { content: '{"calm": "Sorry for the trouble. I will make it right."}' } }] };
    assert.ok(init.body.length > 0);
    return new Response(JSON.stringify(body), { status: 200 });
  });
  const ai = createAi({ typesafeKey: 'k', openrouterKey: 'k' });
  assert.deepEqual(await ai.toneCheck('See you at 3!', ''), { tone: 'ok', calm: null });
  assert.deepEqual(hits, ['api.typesafe.ai']);
  label = '1';
  hits.length = 0;
  assert.deepEqual(await ai.toneCheck('', 'WORST service ever'), { tone: 'upset', calm: 'Sorry for the trouble. I will make it right.' });
  assert.equal(hits[0], 'api.typesafe.ai');
  assert.ok(hits.slice(1).every((h) => h === 'openrouter.ai') && hits.length >= 2);
});

test('write/tone logs its paid calls: 1 when ok, 2 when it writes a calm reply', async (t) => {
  const lines: string[] = [];
  for (const tone of [{ tone: 'ok', calm: null }, { tone: 'upset', calm: 'Sorry.' }] as const) {
    const w = setup({ tone });
    const { token } = w.device();
    t.mock.method(console, 'log', (l: string) => { lines.push(l); });
    process.env.LOG_SILENT = '0';
    try {
      await w.call(token, 'POST', '/v1/write/tone', { context: 'hi' });
    } finally {
      process.env.LOG_SILENT = '1';
      t.mock.restoreAll();
    }
  }
  const paid = lines.map((l) => JSON.parse(l)).filter((e) => e.event === 'write').map((e) => e.paid_calls);
  assert.deepEqual(paid, [1, 2]);
});
