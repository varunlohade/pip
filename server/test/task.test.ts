import { test } from 'node:test';
import assert from 'node:assert/strict';
import { TASK_LIMITS, TaskPlanSchema } from '../src/task.ts';
import { setup } from './helpers.ts';

test('task plan: no token is 401 and the model is not called', async () => {
  const { call, aiCalls } = setup();
  assert.equal((await call(null, 'POST', '/v1/task/plan', { text: 'book me a train to Pune on Friday' })).status, 401);
  assert.equal(aiCalls.length, 0);
});

test('task plan: returns goal, steps and what to confirm; it never pays and asks for the PIN', async () => {
  const { call, device, aiCalls } = setup({
    task: { goal: ' Book a train ticket to Pune on Friday ', steps: [{ do: 'Search Friday trains to Pune', where: 'IRCTC' }, { do: 'Stop before paying and show the price' }], confirm: ['Which class?', ''] },
  });
  const { token } = device();
  const res = await call(token, 'POST', '/v1/task/plan', { text: ' book me a train ticket to Pune on Friday ' });
  assert.equal(res.status, 200);
  const out = await res.json();
  assert.equal(out.goal, 'Book a train ticket to Pune on Friday');
  assert.equal(out.steps.length, 2);
  assert.equal(out.steps[1].where, '');
  assert.deepEqual(out.confirm, ['Which class?']);
  assert.equal(out.pays, false);
  assert.equal(out.approval, 'pin');
  assert.deepEqual(aiCalls, [{ fn: 'taskPlan', args: ['book me a train ticket to Pune on Friday'] }]);
});

test('task plan: caps steps and lengths; an empty plan is refused; a bad body calls no model', async () => {
  const many = TaskPlanSchema.parse({ goal: 'g'.repeat(500), steps: Array.from({ length: 10 }, (_, i) => ({ do: `step ${i}`, where: 'w' })), confirm: ['a', 'b', 'c', 'd', 'e'] });
  assert.equal(many.goal.length, TASK_LIMITS.goal);
  assert.equal(many.steps.length, TASK_LIMITS.steps);
  assert.equal(many.confirm.length, TASK_LIMITS.confirm);
  assert.throws(() => TaskPlanSchema.parse({ goal: 'x', steps: [], confirm: [] }));
  const { call, device, aiCalls } = setup();
  const { token } = device();
  assert.equal((await call(token, 'POST', '/v1/task/plan', { topic: 'x' })).status, 400);
  assert.equal(aiCalls.length, 0);
});

test('task plan: a model failure is a 502, not a crash', async () => {
  const { call, device } = setup({ task: new Error('down') });
  const { token } = device();
  assert.equal((await call(token, 'POST', '/v1/task/plan', { text: 'book a table for two' })).status, 502);
});
