const SENSITIVE = /(token|secret|key|authorization|password|email|name|text|reply|payload|note)/i;

export function redact(v: unknown, depth = 0): unknown {
  if (depth > 4 || v === null || typeof v !== 'object') return v;
  if (Array.isArray(v)) return v.map((x) => redact(x, depth + 1));
  return Object.fromEntries(
    Object.entries(v as Record<string, unknown>).map(([k, x]) => [k, SENSITIVE.test(k) ? '[redacted]' : redact(x, depth + 1)]),
  );
}

export function log(event: string, fields: Record<string, unknown> = {}) {
  if (process.env.LOG_SILENT === '1') return;
  console.log(JSON.stringify({ t: new Date().toISOString(), event, ...(redact(fields) as object) }));
}
