import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { once } from 'node:events';

const script = new URL('../scripts/fake-server.ts', import.meta.url).pathname;

test('fake server: suggest, /_next, writing help and /_log work with the fixed token and no network', async (t) => {
  const child = spawn(process.execPath, [script], { env: { ...process.env, PORT: '0', NODE_ENV: '' }, stdio: ['ignore', 'pipe', 'inherit'] });
  t.after(() => child.kill());
  let out = '';
  child.stdout.setEncoding('utf8');
  while (!/127\.0\.0\.1:(\d+)/.test(out)) out += (await once(child.stdout, 'data'))[0];
  const base = `http://127.0.0.1:${/127\.0\.0\.1:(\d+)/.exec(out)![1]}`;
  const call = async (path: string, body?: unknown, tap = false) => {
    const res = await fetch(base + path, {
      method: body === undefined ? 'GET' : 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: 'Bearer pkd_fake', ...(tap ? { 'X-User-Action': 'tap' } : {}) },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    return { status: res.status, json: (await res.json()) as any };
  };

  assert.equal((await call('/v1/me')).status, 200);
  const plain = await call('/v1/suggest', { text: 'lunch with the team friday' });
  assert.equal(plain.status, 200);
  assert.deepEqual(plain.json.chips, []);

  await call('/_next', { device: { kind: 'event' } });
  const s = await call('/v1/suggest', { text: 'lunch with the team friday' });
  assert.equal(s.json.chips[0].kind, 'event', JSON.stringify(s.json));
  assert.deepEqual(s.json.chips[0].payload, { title: 'Lunch with the team friday' });

  await call('/_next', { write: 'Thanks for coming.' });
  const fixed = await call('/v1/write/fix', { text: 'thnks for comming' }, true);
  assert.deepEqual([fixed.json.text, fixed.json.changed], ['Thanks for coming.', true]);
  assert.equal((await call('/v1/write/fix', { text: 'thnks for comming' }, true)).json.changed, false, '/_next answers once');

  const log = (await call('/_log')).json;
  assert.deepEqual(log.requests[1], { method: 'POST', path: '/v1/suggest', status: 200, body: { text: 'lunch with the team friday' } });
  assert.deepEqual(log.ai.map((c: any) => c.fn), ['deviceAction', 'deviceAction', 'fix', 'fix']);

  await call('/_reset', {});
  assert.equal((await call('/_log')).json.requests.length, 0);
  assert.equal((await call('/v1/suggest', { text: 'hi' })).status, 200);
});

test('fake server: refuses to start in production', () => {
  const r = spawnSync(process.execPath, [script], { env: { ...process.env, PORT: '0', NODE_ENV: 'production' }, encoding: 'utf8', timeout: 10_000 });
  assert.equal(r.status, 1);
  assert.match(r.stderr, /refuses to start/);
});
