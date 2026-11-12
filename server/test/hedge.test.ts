import { test } from 'node:test';
import assert from 'node:assert/strict';
import { hedge } from '../src/ai.ts';

// Fake model: answers (or fails) after `ms`, and records whether it was started and aborted.
function fake(name: string, ms: number, fail = false) {
  const state = { started: false, aborted: false };
  const fn = (signal: AbortSignal) => {
    state.started = true;
    return new Promise<string>((resolve, reject) => {
      const t = setTimeout(() => (fail ? reject(new Error(`${name} failed`)) : resolve(name)), ms);
      signal.addEventListener('abort', () => { state.aborted = true; clearTimeout(t); reject(new Error('aborted')); });
    });
  };
  return { fn, state };
}

test('hedge: a fast primary wins and the backup never starts', async () => {
  const p = fake('llama', 20), b = fake('gemini', 10);
  assert.equal(await hedge(p.fn, b.fn, 70), 'llama');
  assert.equal(b.state.started, false);
});

test('hedge: a slow primary starts the backup at the delay; the first valid result wins, the loser is aborted', async () => {
  const p = fake('llama', 300), b = fake('gemini', 30);
  const t = performance.now();
  assert.equal(await hedge(p.fn, b.fn, 70), 'gemini');
  const ms = performance.now() - t;
  assert.ok(ms >= 95 && ms < 250, `took ${ms} ms`);
  assert.equal(p.state.aborted, true);
});

test('hedge: the primary still wins if it answers after the backup started', async () => {
  const p = fake('llama', 100), b = fake('gemini', 200);
  assert.equal(await hedge(p.fn, b.fn, 70), 'llama');
  assert.equal(b.state.started, true);
  assert.equal(b.state.aborted, true);
});

test('hedge: an early primary failure starts the backup at once', async () => {
  const p = fake('llama', 10, true), b = fake('gemini', 20);
  const t = performance.now();
  assert.equal(await hedge(p.fn, b.fn, 500), 'gemini');
  assert.ok(performance.now() - t < 200);
});

test('hedge: a failed backup falls back to the slow primary; both failing rejects', async () => {
  const p = fake('llama', 150), b = fake('gemini', 10, true);
  assert.equal(await hedge(p.fn, b.fn, 50), 'llama');
  const p2 = fake('llama', 60, true), b2 = fake('gemini', 10, true);
  await assert.rejects(hedge(p2.fn, b2.fn, 20), /failed/);
});
