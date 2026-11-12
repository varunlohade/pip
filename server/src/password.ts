import { randomBytes, scrypt as scryptCb, timingSafeEqual, type ScryptOptions } from 'node:crypto';
import { COMMON_PASSWORDS } from './common-passwords.ts';
import { config } from './config.ts';

// scrypt, because Node has it built in and argon2 would be a new native dependency.
// N = 2^16, r = 8, p = 2 is OWASP's setting: 64 MB (128 * N * r) per hash. config.password.maxConcurrent caps how many run at once.
const N = 2 ** 16, R = 8, P = 2, KEYLEN = 32;
const MAXMEM = 160 * 1024 * 1024;

export const PASSWORD_MIN = 10;
export const PASSWORD_MAX = 256;

/** Too many hashes are waiting. The caller answers 503 with Retry-After. */
export class PasswordBusyError extends Error {}

// A semaphore: `active` hashes run, the rest wait in order. A waiter that times out leaves the queue and throws.
let active = 0;
let peak = 0;
const waiting: (() => void)[] = [];
/** Running hashes now and the most at once since the last reset (for tests). */
export const hashingStats = (reset = false) => {
  const out = { active, peak, waiting: waiting.length };
  if (reset) peak = active;
  return out;
};

async function slot(): Promise<void> {
  if (active < config.password.maxConcurrent) {
    active++;
    peak = Math.max(peak, active);
    return;
  }
  await new Promise<void>((resolve, reject) => {
    const go = () => {
      clearTimeout(timer);
      resolve();
    };
    const timer = setTimeout(() => {
      waiting.splice(waiting.indexOf(go), 1);
      reject(new PasswordBusyError('password hashing is busy'));
    }, config.password.queueTimeoutMs);
    waiting.push(go);
  });
  // The finishing hash handed its slot over, so `active` stays the same.
  peak = Math.max(peak, active);
}

function free() {
  const next = waiting.shift();
  if (next) next();
  else active--;
}

const scrypt = async (pw: string, salt: Buffer, o: ScryptOptions) => {
  await slot();
  try {
    return await new Promise<Buffer>((ok, fail) => scryptCb(pw, salt, KEYLEN, { ...o, maxmem: MAXMEM }, (e, k) => (e ? fail(e) : ok(k))));
  } finally {
    free();
  }
};

// NFC, so the same password typed on two keyboards (é as one or two code points) is the same password.
const norm = (pw: string) => pw.normalize('NFC');

/** `scrypt$<log2 N>$<r>$<p>$<salt>$<hash>`, base64url. The cost travels with the hash, so it can go up later. */
export async function hashPassword(pw: string): Promise<string> {
  const salt = randomBytes(16);
  const key = await scrypt(norm(pw), salt, { N, r: R, p: P });
  return `scrypt$${Math.log2(N)}$${R}$${P}$${salt.toString('base64url')}$${key.toString('base64url')}`;
}

/** True when the stored hash was made with other settings. The next right password hashes it again. */
export const needsRehash = (stored: string) => !stored.startsWith(`scrypt$${Math.log2(N)}$${R}$${P}$`);

export async function verifyPassword(pw: string, stored: string): Promise<boolean> {
  const [alg, logN, r, p, salt, hash] = stored.split('$');
  if (alg !== 'scrypt' || !salt || !hash) return false;
  const want = Buffer.from(hash, 'base64url');
  const got = await scrypt(norm(pw), Buffer.from(salt, 'base64url'), { N: 2 ** Number(logN), r: Number(r), p: Number(p) });
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
