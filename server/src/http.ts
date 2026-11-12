import type { Context, MiddlewareHandler } from 'hono';
import { getConnInfo } from '@hono/node-server/conninfo';
import { config } from './config.ts';

export type Env = { Variables: { userId: string; sessionId: string } };

export class HttpError extends Error {
  status: 400 | 401 | 403 | 404 | 409 | 428 | 429;
  constructor(status: HttpError['status'], message: string) {
    super(message);
    this.status = status;
  }
}

const MAX_KEYS = 100_000;

// Fixed windows per key. The map keeps keys in the order their windows started, so the first key always ends first.
// Each new window drops ended windows from the front, and stops at the first live one. Only a full map drops the oldest
// live window. It never clears everything, or one client with many keys would reset everyone's limit.
export function createLimiter({ limit, windowMs, maxKeys = MAX_KEYS }: { limit: number; windowMs: number; maxKeys?: number }) {
  const hits = new Map<string, { n: number; reset: number }>();
  const entry = (key: string) => {
    const now = Date.now();
    let h = hits.get(key);
    if (!h || h.reset <= now) {
      hits.delete(key);
      for (const [k, v] of hits) {
        if (hits.size < maxKeys && v.reset > now) break;
        hits.delete(k);
      }
      h = { n: 0, reset: now + windowMs };
      hits.set(key, h);
    }
    return h;
  };
  return {
    over: (key: string) => entry(key).n >= limit,
    hit: (key: string) => ++entry(key).n > limit,
    retryAfter: (key: string) => String(Math.max(1, Math.ceil((entry(key).reset - Date.now()) / 1000))),
    size: () => hits.size,
  };
}

/** The limit key for an address: IPv4 as is, IPv6 by its /64 (one home or phone usually owns a whole /64). */
export function ipKey(ip: string): string {
  const v = ip.trim().replace(/%.*$/, '').toLowerCase();
  const mapped = /^::ffff:(\d+\.\d+\.\d+\.\d+)$/.exec(v);
  if (mapped) return mapped[1];
  if (!v.includes(':')) return v;
  const [head, tail] = v.split('::');
  const h = head ? head.split(':') : [];
  const t = tail ? tail.split(':') : [];
  const groups = tail === undefined ? h : [...h, ...Array(Math.max(0, 8 - h.length - t.length)).fill('0'), ...t];
  return `${groups.slice(0, 4).map((g) => g.replace(/^0+(?=.)/, '')).join(':')}::/64`;
}

export function rateLimiter(bucket: keyof typeof config.rateLimit, keyOf: (c: Context<Env>) => string): MiddlewareHandler<Env> {
  const limiter = createLimiter(config.rateLimit[bucket]);
  return async (c, next) => {
    const key = keyOf(c);
    if (limiter.hit(key)) {
      c.header('Retry-After', limiter.retryAfter(key));
      return c.json({ error: 'rate limited' }, 429);
    }
    await next();
  };
}

export function clientIp(c: Context<Env>): string {
  if (config.trustProxy && config.clientIpHeader) {
    const ip = c.req.header(config.clientIpHeader)?.trim();
    if (ip) return ipKey(ip);
  }
  if (config.trustProxy) {
    const hops = (c.req.header('x-forwarded-for') ?? '').split(',').map((h) => h.trim()).filter(Boolean);
    if (hops.length) return ipKey(hops[hops.length - 1]);
  }
  try {
    return ipKey(getConnInfo(c).remote.address ?? 'direct');
  } catch {
    return 'direct';
  }
}
