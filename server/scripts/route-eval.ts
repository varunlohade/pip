// Live eval of the /v1/route question on test/fixtures/route-eval.json (12 lines per label, 30 everyday chat lines).
// Three ways: jev direct (TypeSafe), jev on NEAR AI Cloud, and the NEAR TEE model Qwen writing a JSON label.
// Prints accuracy, per-label precision and recall, p50/p95 latency, and the confidence each label needs for 0.9 precision.
// Keys come from server/.env and are never printed. Run: cd server && node --env-file=.env scripts/route-eval.ts [jev|near-jev|qwen]
import { writeFileSync } from 'node:fs';
import { config } from '../src/config.ts';
import { ROUTE_CRITERIA, ROUTE_LABELS, ROUTE_QUESTION, ROUTE_SYSTEM, routeContext, type RouteLabel } from '../src/route.ts';
import data from '../test/fixtures/route-eval.json' with { type: 'json' };

type Row = { text: string; want: RouteLabel; got: RouteLabel; confidence: number; ms: number };
const post = async (url: string, key: string, body: unknown) => {
  const res = await fetch(url, { method: 'POST', headers: { Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' }, body: JSON.stringify(body), signal: AbortSignal.timeout(20_000) });
  if (!res.ok) throw new Error(`${url} ${res.status}`);
  return res.json();
};
const jevBody = (model: string, text: string) => ({
  model, state: { context: routeContext(text) },
  questions: { q: { type: 'choice', criteria: Object.fromEntries(ROUTE_LABELS.map((l, i) => [String(i + 1), ROUTE_CRITERIA[l]])), instructions: { question: ROUTE_QUESTION } } },
});
const fromJev = (j: any) => ({ got: ROUTE_LABELS[Number(j?.answers?.q?.choice) - 1] ?? 'none', confidence: Number(j?.answers?.q?.confidence ?? 0) });
const backends: Record<string, (text: string) => Promise<{ got: RouteLabel; confidence: number }>> = {
  jev: async (t) => fromJev(await post(config.jev.url, process.env.TYPESAFE_API_KEY!, jevBody(config.jev.model, t))),
  'near-jev': async (t) => fromJev(await post(`${config.nearai.url}/systemone`, process.env.NEARAI_API_KEY!, jevBody('typesafe/jev-1.13', t))),
  qwen: async (t) => {
    const m = 'Qwen/Qwen3.6-35B-A3B-FP8';
    const j = await post(`${config.nearai.url}/chat/completions`, process.env.NEARAI_API_KEY!, {
      model: m, ...config.nearai.params[m], temperature: 0, max_tokens: 40,
      messages: [{ role: 'system', content: ROUTE_SYSTEM }, { role: 'user', content: routeContext(t) }],
    });
    const out = JSON.parse(j.choices[0].message.content);
    return { got: (ROUTE_LABELS as readonly string[]).includes(out.label) ? out.label : 'none', confidence: Number(out.confidence ?? 0) };
  },
};

const pick = process.argv[2];
const lines = Object.entries(data).flatMap(([want, list]) => list.map((text) => ({ text, want: want as RouteLabel })));
const runs = await Promise.all(Object.entries(backends).filter(([name]) => !pick || name === pick).map(async ([name, ask]) => {
  const rows: Row[] = [];
  for (const l of lines) {
    const t = performance.now();
    try { rows.push({ ...l, ...(await ask(l.text)), ms: Math.round(performance.now() - t) }); }
    catch (e) { rows.push({ ...l, got: 'none', confidence: 0, ms: Math.round(performance.now() - t) }); console.error(name, 'error', (e as Error).message); }
  }
  return [name, rows] as const;
}));

const out: Record<string, unknown> = {};
for (const [name, rows] of runs) {
  const ms = rows.map((r) => r.ms).sort((a, b) => a - b);
  const q = (p: number) => ms[Math.min(ms.length - 1, Math.floor(ms.length * p))];
  console.log(`\n== ${name}: accuracy ${(rows.filter((r) => r.got === r.want).length / rows.length).toFixed(3)}  p50 ${q(0.5)} ms  p95 ${q(0.95)} ms`);
  console.log('label                 prec  recall  need(p>=0.9)  prec@need  recall@need');
  const need: Record<string, number> = {};
  for (const l of ROUTE_LABELS) {
    const pr = (th: number) => {
      const hit = rows.filter((r) => r.got === l && r.confidence >= th);
      const tp = hit.filter((r) => r.want === l).length;
      return { p: hit.length ? tp / hit.length : 1, r: tp / rows.filter((r) => r.want === l).length };
    };
    const base = pr(0);
    const th = [0, 0.5, 0.6, 0.7, 0.8, 0.9, 0.95].find((t) => pr(t).p >= 0.9) ?? 1;
    need[l] = th;
    const at = pr(th);
    console.log(`${l.padEnd(22)}${base.p.toFixed(2)}  ${base.r.toFixed(2)}    ${th.toFixed(2)}          ${at.p.toFixed(2)}       ${at.r.toFixed(2)}`);
  }
  for (const r of rows) if (r.got !== r.want) console.log(`  miss ${r.want} -> ${r.got} ${r.confidence.toFixed(2)}  ${r.text}`);
  out[name] = { need, rows };
}
writeFileSync(new URL('../test/fixtures/route-eval-results.json', import.meta.url), JSON.stringify(out, null, 1));
