import { createPublicKey, timingSafeEqual, verify } from 'node:crypto';
import { config } from './config.ts';
import { sha256 } from './crypto.ts';

export type AppleJwk = { kty: string; kid: string; n: string; e: string; alg?: string; use?: string };
export type AppleVerifier = (identityToken: string, rawNonce: string) => Promise<{ sub: string }>;

const part = (s: string) => JSON.parse(Buffer.from(s, 'base64url').toString('utf8')) as Record<string, unknown>;
const same = (a: string, b: string) => a.length === b.length && timingSafeEqual(Buffer.from(a), Buffer.from(b));

export async function fetchAppleKeys(): Promise<AppleJwk[]> {
  const r = await fetch(config.apple.jwksUrl, { signal: AbortSignal.timeout(config.apple.timeoutMs) });
  if (!r.ok) throw new Error(`apple jwks ${r.status}`);
  return ((await r.json()) as { keys: AppleJwk[] }).keys;
}

// Checks an Apple identity token: RS256 signature against Apple's keys, then iss, aud, exp and the nonce.
// The app sends SHA-256(nonce) to Apple and the raw nonce to us, so a token made for another sign-in fails here.
// Every failure throws. The caller answers 401 and gives no detail.
export function createAppleVerifier(o: { audience?: string; fetchKeys?: () => Promise<AppleJwk[]>; now?: () => number } = {}): AppleVerifier {
  const audience = o.audience ?? config.apple.audience;
  const fetchKeys = o.fetchKeys ?? fetchAppleKeys;
  const now = o.now ?? Date.now;
  let keys: AppleJwk[] = [];
  let fetchedAt = 0;

  const keyFor = async (kid: string) => {
    const stale = now() - fetchedAt > config.apple.jwksTtlMs;
    let key = stale ? undefined : keys.find((k) => k.kid === kid);
    // An unknown kid can mean Apple rotated its keys, so fetch again, but not more than once a minute.
    if (!key && (stale || now() - fetchedAt > config.apple.jwksMinRefetchMs)) {
      keys = await fetchKeys();
      fetchedAt = now();
      key = keys.find((k) => k.kid === kid);
    }
    if (!key) throw new Error('unknown key id');
    return key;
  };

  return async (identityToken, rawNonce) => {
    const parts = identityToken.split('.');
    if (parts.length !== 3) throw new Error('not a JWT');
    const header = part(parts[0]);
    if (header.alg !== 'RS256' || typeof header.kid !== 'string') throw new Error('bad header');
    const jwk = await keyFor(header.kid);
    if (jwk.kty !== 'RSA') throw new Error('bad key type');
    const ok = verify('RSA-SHA256', Buffer.from(`${parts[0]}.${parts[1]}`), createPublicKey({ key: jwk, format: 'jwk' }), Buffer.from(parts[2], 'base64url'));
    if (!ok) throw new Error('bad signature');

    const claims = part(parts[1]);
    if (claims.iss !== config.apple.issuer) throw new Error('bad iss');
    const aud = Array.isArray(claims.aud) ? claims.aud : [claims.aud];
    if (!aud.includes(audience)) throw new Error('bad aud');
    if (typeof claims.exp !== 'number' || claims.exp * 1000 <= now()) throw new Error('expired');
    if (typeof claims.nonce !== 'string' || !same(claims.nonce, sha256(rawNonce))) throw new Error('bad nonce');
    if (typeof claims.sub !== 'string' || !claims.sub) throw new Error('no sub');
    return { sub: claims.sub };
  };
}
