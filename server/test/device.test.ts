import { test } from 'node:test';
import assert from 'node:assert/strict';
import { deviceSignal, deviceTitle, deviceTrigger } from '../src/quick.ts';
import { setup } from './helpers.ts';

const suggest = async (s: ReturnType<typeof setup>, token: string, text: string, context?: string) =>
  (await s.call(token, 'POST', '/v1/suggest', { text, ...(context ? { context } : {}) })).json();

test('suggest: each input takes one path, and paid calls match the model calls made', async () => {
  const rows: [string, 'regex_none' | 'jev_device', number][] = [
    // Plain chat: the regex gate ends it, no call.
    ['lol ok', 'regex_none', 0],
    ['see you tomorrow', 'regex_none', 0],
    ['thanks so much', 'regex_none', 0],
    ['haha that is so funny', 'regex_none', 0],
    ['sounds good to me', 'regex_none', 0],
    ['see you soon then', 'regex_none', 0],
    // Action-ish: one jev question.
    ["can we move Ana's thing", 'jev_device', 1],
    ['call the supplier about the order', 'jev_device', 1],
    ['follow up with Bo next week', 'jev_device', 1],
    ['dentist moved to the 14th', 'jev_device', 1],
    ['what time works for you?', 'jev_device', 1],
    ['gate code is 4521 now', 'jev_device', 1],
    ['lunch with the team friday', 'jev_device', 1],
    ['Great. need to order more shampoo', 'jev_device', 1],
  ];
  for (const [text, want, calls] of rows) {
    const s = setup({ device: { kind: 'reminder' } });
    const { token } = s.device();
    await suggest(s, token, text);
    const fns = s.aiCalls.map((c) => c.fn);
    const path = fns.length === 0 ? 'regex_none' : fns[0] === 'deviceAction' ? 'jev_device' : 'other';
    assert.equal(path, want, `${text}: ${fns}`);
    assert.equal(fns.length, calls, text);
  }
});

test('suggest: device chips carry a title and a trigger; the phone fills the time', async () => {
  const kinds = [
    ['event', 'lunch with the team friday', { title: 'Lunch with the team friday' }],
    ['reminder', 'call the supplier about the order', { title: 'Call the supplier about the order' }],
    ['note', 'gate code is 4521 now', { text: 'gate code is 4521 now' }],
    ['followup', "can we move Ana's thing?", { title: 'Follow up with Ana' }],
  ] as const;
  for (const [kind, text, payload] of kinds) {
    const s = setup({ device: { kind } });
    const { token } = s.device();
    const r = await suggest(s, token, text);
    assert.equal(r.chips.length, 1, text);
    assert.equal(r.chips[0].kind, kind);
    assert.deepEqual(r.chips[0].payload, payload, text);
    assert.equal(r.chips[0].needs_confirm, false);
    assert.ok(r.chips[0].trigger, `${text}: has a trigger`);
  }
});

test('suggest: a device guess with low confidence, none, or a failed call gives no chip', async () => {
  for (const device of [{ kind: 'event' as const, confidence: 0.3 }, { kind: 'none' as const }, new Error('jev down')]) {
    const s = setup({ device });
    const { token } = s.device();
    const res = await s.call(token, 'POST', '/v1/suggest', { text: 'lunch with the team friday' });
    assert.equal(res.status, 200);
    assert.deepEqual((await res.json()).chips, []);
  }
});

test('suggest: copied client text never reaches the device path', async () => {
  const s = setup({ device: { kind: 'event' } });
  const { token } = s.device();
  const r = await suggest(s, token, 'ok', 'can we meet friday at 3?');
  assert.deepEqual(r.chips, []);
  assert.equal(s.aiCalls.length, 0);
});

test('triggers and titles', () => {
  assert.equal(deviceTrigger("can we move Ana's thing"), 'Ana');
  assert.equal(deviceTrigger('call the supplier about it'), 'call');
  assert.equal(deviceTitle("ok, can we move Ana's thing?"), "Move Ana's thing");
  assert.equal(deviceTitle('I need to order more shampoo.'), 'Order more shampoo');
  assert.equal(deviceSignal('lol ok see you'), false);
  assert.equal(deviceSignal('call the supplier about it'), true);
});
