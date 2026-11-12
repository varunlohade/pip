import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createAi } from '../src/ai.ts';
import { config } from '../src/config.ts';
import { CANVAS, ExplanationSchema, LIMITS, SceneSchema, type SceneShape } from '../src/explain.ts';
import { setup } from './helpers.ts';
import logScene from './fixtures/log-scene.json' with { type: 'json' };

const inside = (s: SceneShape) => {
  const xs = s.type === 'line' ? s.points.map((p) => p[0]) : s.type === 'arrow' ? [s.x1, s.x2] : [s.x];
  const ys = s.type === 'line' ? s.points.map((p) => p[1]) : s.type === 'arrow' ? [s.y1, s.y2] : [s.y];
  return xs.every((x) => x >= 0 && x <= CANVAS.w) && ys.every((y) => y >= 0 && y <= CANVAS.h);
};

test('explain: no token is 401 and the model is not called', async () => {
  const { call, aiCalls } = setup();
  assert.equal((await call(null, 'POST', '/v1/explain', { text: 'explain log function' })).status, 401);
  assert.equal((await call(null, 'POST', '/v1/explain/visual', { topic: 'log function' })).status, 401);
  assert.equal(aiCalls.length, 0);
});

test('explain: returns short, body (at most 4 lines) and visual_ok; the model gets cleaned text', async () => {
  const { call, device, aiCalls } = setup({
    explain: { short: ' Interest on interest. ', body: ['You earn on what you saved.', 'Then on what it earned.', 'And again.', 'And again.', 'A fifth line goes.'], visual_ok: 'yes' },
  });
  const { token } = device();
  const res = await call(token, 'POST', '/v1/explain', { text: ' eli5\ncompound​ interest ' });
  assert.equal(res.status, 200);
  const out = await res.json();
  assert.equal(out.short, 'Interest on interest.');
  assert.equal(out.body.split('\n').length, LIMITS.lines);
  assert.equal(out.visual_ok, true);
  assert.deepEqual(aiCalls, [{ fn: 'explain', args: ['eli5 compound interest'] }]);
});

test('explain: validation and size caps; a bad body calls no model', async () => {
  const { call, device, aiCalls } = setup();
  const { token } = device();
  const bad: [string, unknown][] = [
    ['/v1/explain', {}],
    ['/v1/explain', { text: '  ' }],
    ['/v1/explain', { text: 'x'.repeat(config.maxExplainChars + 1) }],
    ['/v1/explain', { text: 'explain logs', extra: 1 }],
    ['/v1/explain/visual', { text: 'log function' }],
    ['/v1/explain/visual', { topic: 'x'.repeat(config.maxExplainChars + 1) }],
  ];
  for (const [path, b] of bad) assert.equal((await call(token, 'POST', path, b)).status, 400, `${path} ${JSON.stringify(b).slice(0, 40)}`);
  assert.equal(aiCalls.length, 0);
});

test('explain: a model failure or a bad answer is a 502 with no detail', async () => {
  for (const explain of [new Error('boom "secret question"'), { short: '', body: [] }, { nope: true }]) {
    const { call, device } = setup({ explain });
    const { token } = device();
    const res = await call(token, 'POST', '/v1/explain', { text: 'secret question' });
    assert.equal(res.status, 502);
    assert.ok(!(await res.text()).includes('secret'));
  }
});

test('explain: rate limit per user, shared by both routes', async () => {
  const { call, device } = setup();
  const a = device(), b = device();
  let last = 0;
  for (let i = 0; i < config.rateLimit.explain.limit; i++) {
    last = (await call(a.token, 'POST', i % 2 ? '/v1/explain' : '/v1/explain/visual', i % 2 ? { text: 'explain logs' } : { topic: 'logs' })).status;
    assert.equal(last, 200);
  }
  assert.equal((await call(a.token, 'POST', '/v1/explain', { text: 'explain logs' })).status, 429);
  assert.equal((await call(a.token, 'POST', '/v1/explain/visual', { topic: 'logs' })).status, 429);
  assert.equal((await call(b.token, 'POST', '/v1/explain', { text: 'explain logs' })).status, 200);
  // Each call counts once: b has used 1 of its budget, so limit - 1 more still pass.
  for (let i = 1; i < config.rateLimit.explain.limit; i++) assert.equal((await call(b.token, 'POST', '/v1/explain', { text: 'explain logs' })).status, 200, `call ${i + 1}`);
  assert.equal((await call(b.token, 'POST', '/v1/explain', { text: 'explain logs' })).status, 429);
});

test('explain: nothing from the question reaches the log', async (t) => {
  const { call, device } = setup();
  const { token } = device();
  const lines: string[] = [];
  t.mock.method(console, 'log', (l: string) => { lines.push(l); });
  process.env.LOG_SILENT = '0';
  try {
    await call(token, 'POST', '/v1/explain', { text: 'explain TOPSECRET' });
    await call(token, 'POST', '/v1/explain/visual', { topic: 'TOPSECRET' });
  } finally {
    process.env.LOG_SILENT = '1';
  }
  assert.equal(lines.filter((l) => l.includes('"event":"explain"')).length, 2);
  assert.ok(!lines.join('\n').includes('TOPSECRET'));
});

test('visual: the log scene comes back as steps of plain shapes, the plot sampled by the server', async () => {
  const { call, device, aiCalls } = setup();
  const { token } = device();
  const res = await call(token, 'POST', '/v1/explain/visual', { topic: 'log function' });
  assert.equal(res.status, 200);
  const scene = await res.json();
  assert.deepEqual(aiCalls, [{ fn: 'visual', args: ['log function'] }]);
  assert.deepEqual(scene.canvas, CANVAS);
  assert.ok(scene.steps.length >= 2 && scene.steps.length <= LIMITS.steps);
  const shapes: SceneShape[] = scene.steps.flatMap((s: { shapes: SceneShape[] }) => s.shapes);
  assert.ok(shapes.every((s) => ['text', 'rect', 'ellipse', 'arrow', 'line'].includes(s.type)));
  assert.ok(shapes.every(inside));
  const curve = scene.steps[1].shapes.find((s: SceneShape) => s.type === 'line');
  assert.ok(curve && curve.points.length > 20, 'the plot is a sampled line');
  // y = log10(x) rises: screen y falls as x grows.
  const ys = curve.points.map((p: number[]) => p[1]);
  assert.ok(ys.every((y: number, i: number) => i === 0 || y <= ys[i - 1]));
});

test('visual: clamps coordinates and text, caps steps and shapes, drops bad shapes, fixes colors', () => {
  const many = Array.from({ length: 40 }, (_, i) => ({ type: 'rect', x: i, y: i, w: 20, h: 20 }));
  const scene = SceneSchema.parse({
    title: 't'.repeat(200),
    steps: [
      { say: 's'.repeat(500), shapes: [
        { type: 'text', x: -500, y: 99999, text: 'x'.repeat(300), color: 'hot-pink' },
        { type: 'arrow', x1: 1e9, y1: -1, x2: 'NaN', y2: 4 },
        { type: 'circle', x: 1, y: 1 },
        { type: 'line', points: Array.from({ length: 500 }, (_, i) => [i, i]) },
        { type: 'plot', fn: 'eval("x")' },
      ] },
      { say: 'two', shapes: many },
      { say: 'three', shapes: many },
      { say: 'four', shapes: [{ type: 'ellipse', x: 1, y: 1, w: 5, h: 5 }] },
      { say: 'five', shapes: [{ type: 'ellipse', x: 1, y: 1, w: 50, h: 50 }] },
    ],
  });
  assert.equal(scene.title.length, LIMITS.title);
  assert.equal(scene.steps[0].say.length, LIMITS.say);
  const [t, l] = scene.steps[0].shapes;
  assert.deepEqual([t.type, (t as any).x, (t as any).y, (t as any).text.length, (t as any).color], ['text', 0, CANVAS.h, LIMITS.text, 'black']);
  assert.equal(l.type, 'line');
  assert.equal((l as any).points.length, LIMITS.points);
  assert.equal(scene.steps[0].shapes.length, 2, 'the bad arrow, the unknown type and the bad plot are dropped');
  const total = scene.steps.reduce((n, s) => n + s.shapes.length, 0);
  assert.equal(total, LIMITS.shapes);
  assert.ok(scene.steps.length <= LIMITS.steps);
  assert.ok(scene.steps.flatMap((s) => s.shapes).every(inside));
});

test('visual: axes get tick marks and numbers; the log fixture has x 2..10 and y -1, 1', () => {
  const { steps } = SceneSchema.parse(logScene);
  const labels = steps[0].shapes.filter((s) => s.type === 'text').map((s) => (s as { text: string }).text);
  for (const t of ['2', '4', '6', '8', '10', '-1', '1', 'x', 'y']) assert.ok(labels.includes(t), `missing ${t} in ${labels}`);
  const ticks = steps[0].shapes.filter((s) => s.type === 'line' && s.points.length === 2);
  assert.equal(ticks.length, 7);
  assert.ok(steps[3].shapes.some((s) => s.type === 'text' && s.text === 'climbs, but slowly'));
});

test('explain text keeps powers: 10² stays 10^2, not 102', () => {
  assert.equal(ExplanationSchema.parse({ short: '10² = 100', body: ['2¹⁰ = 1024'], visual_ok: false }).short, '10^2 = 100');
  assert.equal(ExplanationSchema.parse({ short: 'x', body: ['2¹⁰ = 1024'], visual_ok: false }).body, '2^10 = 1024');
});

test('visual: a plot with no axes draws nothing, and a scene with no shapes is rejected', () => {
  assert.throws(() => SceneSchema.parse({ title: 'x', steps: [{ say: 'a', shapes: [{ type: 'plot', fn: 'ln' }] }] }));
  assert.throws(() => SceneSchema.parse({ title: 'x', steps: [] }));
  assert.throws(() => ExplanationSchema.parse({ short: 'ok', body: '' }));
});

test('createAi: explain and visual send one call to the primary model and parse its JSON', async (t) => {
  const bodies: any[] = [];
  const answers = [
    '```json\n{"short":"A log is the power you need.","body":["log10(100) = 2"],"visual_ok":true}\n```',
    JSON.stringify({ title: 'Logs', steps: [{ say: 'Axes', shapes: [{ type: 'axes', x: 40, y: 40, w: 400, h: 300, x_min: 0, x_max: 10, y_min: -2, y_max: 1 }, { type: 'plot', fn: 'log10' }] }] }),
  ];
  t.mock.method(globalThis, 'fetch', async (_url: string, init: RequestInit) => {
    bodies.push(JSON.parse(String(init.body)));
    return new Response(JSON.stringify({ choices: [{ message: { content: answers[bodies.length - 1] } }] }));
  });
  const ai = createAi({ typesafeKey: 'k', openrouterKey: 'k' });
  assert.deepEqual(await ai.explain('explain log function'), { short: 'A log is the power you need.', body: 'log10(100) = 2', visual_ok: true });
  const scene = await ai.visual('log function');
  // One sampled curve; the other lines are two-point tick marks.
  assert.equal(scene.steps[0].shapes.filter((s) => s.type === 'line' && s.points.length > 2).length, 1);
  assert.equal(bodies.length, 2);
  assert.ok(bodies.every((b) => b.model === config.llm.primary.model));
  assert.equal(bodies[0].messages[1].content, 'explain log function');
});

test('createAi: a bad primary answer falls back once to the second model', async (t) => {
  const models: string[] = [];
  t.mock.method(globalThis, 'fetch', async (_url: string, init: RequestInit) => {
    const b = JSON.parse(String(init.body));
    models.push(b.model);
    const content = models.length === 1 ? 'not json' : '{"short":"ok","body":["fine"],"visual_ok":false}';
    return new Response(JSON.stringify({ choices: [{ message: { content } }] }));
  });
  const ai = createAi({ typesafeKey: 'k', openrouterKey: 'k' });
  assert.equal((await ai.explain('what is a vpn')).short, 'ok');
  assert.deepEqual(models, [config.llm.primary.model, config.llm.fallback.model]);
});
