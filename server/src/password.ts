import { randomBytes, scrypt as scryptCb, timingSafeEqual, type ScryptOptions } from 'node:crypto';
import { COMMON_PASSWORDS } from './common-passwords.ts';

// scrypt, because Node has it built in and argon2 would be a new native dependency.
// N = 2^15, r = 8, p = 1 is the OWASP floor for scrypt: about 32 MB and tens of ms per hash.
const N = 2 ** 15, R = 8, P = 1, KEYLEN = 32;
const MAXMEM = 64 * 1024 * 1024;

export const PASSWORD_MIN = 10;
export const PASSWORD_MAX = 256;

const scrypt = (pw: string, salt: Buffer, o: ScryptOptions) =>
  new Promise<Buffer>((ok, fail) => scryptCb(pw, salt, KEYLEN, o, (e, k) => (e ? fail(e) : ok(k))));

// NFC, so the same password typed on two keyboards (é as one or two code points) is the same password.
const norm = (pw: string) => pw.normalize('NFC');

/** `scrypt$<log2 N>$<r>$<p>$<salt>$<hash>`, base64url. The cost travels with the hash, so it can go up later. */
export async function hashPassword(pw: string): Promise<string> {
  const salt = randomBytes(16);
  const key = await scrypt(norm(pw), salt, { N, r: R, p: P, maxmem: MAXMEM });
  return `scrypt$${Math.log2(N)}$${R}$${P}$${salt.toString('base64url')}$${key.toString('base64url')}`;
}

export async function verifyPassword(pw: string, stored: string): Promise<boolean> {
  const [alg, logN, r, p, salt, hash] = stored.split('$');
  if (alg !== 'scrypt' || !salt || !hash) return false;
  const want = Buffer.from(hash, 'base64url');
  const got = await scrypt(norm(pw), Buffer.from(salt, 'base64url'), { N: 2 ** Number(logN), r: Number(r), p: Number(p), maxmem: MAXMEM });
  return got.length === want.length && timingSafeEqual(got, want);
}

/** A plain line for the owner when the password is too weak, or null when it is fine. */
export function passwordProblem(pw: string, email?: string): string | null {
  const p = norm(pw);
  if ([...p].length < PASSWORD_MIN) return `Use at least ${PASSWORD_MIN} characters.`;
  if (p.length > PASSWORD_MAX) return 'That password is too long.';
  const low = p.toLowerCase();
  if (COMMON_PASSWORDS.has(low) || new Set(low).size < 4) return 'That password is too easy to guess. Try a short sentence.';
  const local = email?.split('@')[0]?.toLowerCase();
  if (local && local.length >= 4 && low.includes(local)) return 'Do not put your email in your password.';
  return null;
}
