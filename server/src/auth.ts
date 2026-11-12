import { randomBytes, randomInt, timingSafeEqual } from 'node:crypto';
import type { Context, Hono } from 'hono';
import { z } from 'zod';
import { config } from './config.ts';
import { randomToken, sha256, type Cipher } from './crypto.ts';
import type { CodePurpose, Db, UserRow } from './db.ts';
import { clientIp, createLimiter, HttpError, rateLimiter, type Env } from './http.ts';
import { log } from './log.ts';
import type { Mailer, MailKind } from './mailer.ts';
import { hashPassword, passwordProblem, PASSWORD_MAX, verifyPassword } from './password.ts';
import type { AppleVerifier } from './apple.ts';

export type AuthDeps = {
  db: Db; cipher: Cipher; mailer: Mailer; apple: AppleVerifier; now: () => number;
  onNewUser?: (userId: string) => void;
};
export type Tokens = { access_token: string; refresh_token: string; expires_in: number };

const Email = z.string().trim().toLowerCase().pipe(z.email().max(254));
const Password = z.string().min(1).max(PASSWORD_MAX);
const Code = z.string().trim().regex(/^\d{6}$/);
const EmailPassword = z.object({ email: Email, password: Password }).strict();
const AppleBody = z.object({ identity_token: z.string().min(20).max(4096), nonce: z.string().min(16).max(128) }).strict();
const DeviceBody = z.object({ device_id: z.string().uuid() }).strict();

// One answer for every bad email/password pair, so a caller cannot tell an unknown email from a wrong password.
const WRONG = { error: 'wrong email or password' } as const;
const BAD_CODE = { error: 'that code is wrong or has expired' } as const;
const CHECK_EMAIL = { status: 'check_email' } as const;

const json = async (c: Context<Env>) => {
  try {
    return await c.req.json();
  } catch {
    throw new HttpError(400, 'body must be JSON');
  }
};

export function createAuth(d: AuthDeps) {
  const { db, cipher, mailer, now } = d;
  const emailKey = (email: string) => cipher.lookupHash('email', email);
  const codeHash = (userId: string, purpose: CodePurpose, code: string) => cipher.lookupHash('code', `${userId}:${purpose}:${code}`);
  const mailLimit = createLimiter(config.rateLimit.mailPerEmail);
  // A real scrypt hash of a random password: an unknown email is checked against it, so it costs the same time as a wrong password.
  let dummy: Promise<string> | undefined;
  const dummyHash = () => (dummy ??= hashPassword(randomBytes(16).toString('hex')));

  /** A new session: a short access token and the first refresh token of its family. Only their hashes are stored. */
  function issue(userId: string, label: string, sessionId = db.createSession(userId, label)): Tokens {
    const access = randomToken('pat'), refresh = randomToken('prt');
    db.addAccessToken(sessionId, sha256(access), now() + config.auth.accessTtlMs);
    db.addRefreshToken(sessionId, sha256(refresh), now() + config.auth.refreshTtlMs);
    return { access_token: access, refresh_token: refresh, expires_in: Math.floor(config.auth.accessTtlMs / 1000) };
  }

  /**
   * Mail goes out without waiting, so how long a reply takes never says whether an email was sent.
   * Over the per-email limit nothing is sent and no new code is made, so asking again cannot buy fresh guesses.
   */
  function mail(emailHashKey: string, to: string, kind: MailKind, makeCode?: () => string) {
    if (mailLimit.hit(emailHashKey)) {
      log('mail_limited', { kind });
      return;
    }
    const code = makeCode?.();
    mailer.send({ to, kind, code }).catch((e) => log('mail_failed', { kind, err: (e as Error).name }));
  }

  function newCode(userId: string, purpose: CodePurpose, extra: { emailHash?: string; emailEnc?: string; passwordHash?: string } = {}) {
    const code = String(randomInt(0, 1_000_000)).padStart(6, '0');
    db.putCode({ userId, purpose, codeHash: codeHash(userId, purpose, code), expiresAt: now() + config.auth.codeTtlMs, ...extra });
    return code;
  }

  /**
   * The row once for a right, live code; the code is then gone. A wrong one counts a try; the fifth wrong try ends it.
   * Wrong tries also count per user across every code, so new codes do not buy new guesses: 10 a day, then no code works.
   */
  function useCode(userId: string, purpose: CodePurpose, code: string): ReturnType<Db['code']> {
    const capKey = `code:${userId}`;
    const cap = db.failures(capKey);
    const capCount = cap && now() - cap.last_at < config.auth.failureWindowMs ? cap.count : 0;
    if (capCount >= config.auth.codeDailyMisses) return undefined;
    const row = db.code(userId, purpose);
    const got = Buffer.from(codeHash(userId, purpose, code));
    if (!row || row.expires_at <= now() || row.attempts >= config.auth.codeMaxAttempts) return undefined;
    const want = Buffer.from(row.code_hash);
    if (want.length !== got.length || !timingSafeEqual(want, got)) {
      db.codeAttempt(userId, purpose);
      db.setFailures(capKey, capCount + 1, 0);
      return undefined;
    }
    db.deleteCode(userId, purpose);
    db.clearFailures(capKey);
    return row;
  }

  function lockedFor(key: string): number {
    const f = db.failures(key);
    return f && f.locked_until > now() ? f.locked_until - now() : 0;
  }
  function failed(key: string) {
    const f = db.failures(key);
    const count = (f && now() - f.last_at < config.auth.failureWindowMs ? f.count : 0) + 1;
    const a = config.auth;
    const lock = count >= a.lockAfter ? now() + Math.min(a.lockBaseMs * 2 ** (count - a.lockAfter), a.lockMaxMs) : 0;
    db.setFailures(key, count, lock);
  }
  const locked = (c: Context<Env>, ms: number) => {
    c.header('Retry-After', String(Math.ceil(ms / 1000)));
    return c.json({ error: 'too many tries. wait a while, then try again' }, 429);
  };

  /** Checks an Apple identity token, then spends its nonce: a captured token and nonce work once. */
  async function apple(body: unknown): Promise<string> {
    const b = AppleBody.parse(body);
    const { sub, exp } = await d.apple(b.identity_token, b.nonce);
    if (!db.useNonce(cipher.lookupHash('apple-nonce', b.nonce), exp ?? now() + 600_000)) throw new Error('nonce replay');
    return sub;
  }

  const anonymous = (u: UserRow) => !u.email_hash && !u.apple_sub_hash;

  /** Routes that need no token. They sit before the token check. */
  function publicRoutes(app: Hono<Env>) {
    const ip = rateLimiter('emailAuth', clientIp);

    // "Skip for now": a device account. Every call makes a new user; device_id is never looked up.
    app.post('/v1/auth/device', rateLimiter('deviceAuth', clientIp), async (c) => {
      if (!DeviceBody.safeParse(await c.req.json().catch(() => null)).success) return c.json({ error: 'device_id must be a UUID' }, 400);
      const userId = db.createUser();
      d.onNewUser?.(userId);
      log('device_auth', { user_id: userId });
      return c.json(issue(userId, 'device'));
    });

    // A build from before sessions holds a long-lived device token. It trades it once for a session; the old token is deleted.
    app.post('/v1/auth/device/exchange', rateLimiter('auth', clientIp), async (c) => {
      const b = z.object({ device_token: z.string().regex(/^pkd_[A-Za-z0-9_-]{20,100}$/) }).strict().safeParse(await c.req.json().catch(() => null));
      const userId = b.success ? db.takeDevice(sha256(b.data.device_token)) : undefined;
      if (!userId) return c.json({ error: 'unauthorized' }, 401);
      log('device_exchange', { user_id: userId });
      return c.json(issue(userId, 'device'));
    });

    // Sign in with Apple. Every failure is the same 401; the reason goes only to the log.
    app.post('/v1/auth/apple', rateLimiter('auth', clientIp), async (c) => {
      let sub: string;
      try {
        sub = await apple(await c.req.json());
      } catch (e) {
        log('apple_auth_rejected', { reason: e instanceof z.ZodError ? 'bad body' : (e as Error).message });
        return c.json({ error: 'unauthorized' }, 401);
      }
      const { userId, created } = db.userForAppleSub(cipher.lookupHash('apple-sub', sub));
      if (created) d.onNewUser?.(userId);
      log('apple_auth', { user_id: userId, created });
      return c.json(issue(userId, 'apple'));
    });

    // Sign-up always answers "check your email", whether or not the email has an account, so it cannot be used to test emails.
    // A new email gets a code. A verified one gets a note that it already has an account. An unverified one gets a new code.
    // The password that counts is the one sent with the code to /verify: only the email's owner has the code.
    app.post('/v1/auth/email/signup', ip, async (c) => {
      const { email, password } = EmailPassword.parse(await json(c));
      const problem = passwordProblem(password, email);
      if (problem) return c.json({ error: problem }, 400);
      const hash = await hashPassword(password);
      const key = emailKey(email);
      const u = db.userByEmailHash(key);
      if (!u) {
        const userId = db.createEmailUser(key, (id) => cipher.encrypt(id, email), hash);
        d.onNewUser?.(userId);
        mail(key, email, 'verify', () => newCode(userId, 'verify'));
        log('email_signup', { user_id: userId });
      } else if (u.email_verified_at) {
        mail(key, email, 'exists');
      } else {
        // Nobody has proved they own this email yet, so its password is not touched here: /verify sets it.
        mail(key, email, 'verify', () => newCode(u.id, 'verify'));
      }
      return c.json(CHECK_EMAIL, 202);
    });

    app.post('/v1/auth/email/verify', ip, async (c) => {
      const b = z.object({ email: Email, code: Code, password: Password }).strict().safeParse(await json(c));
      if (!b.success) return c.json(BAD_CODE, 400);
      const problem = passwordProblem(b.data.password, b.data.email);
      if (problem) return c.json({ error: problem }, 400);
      const hash = await hashPassword(b.data.password);
      const u = db.userByEmailHash(emailKey(b.data.email));
      if (!u || u.email_verified_at || !useCode(u.id, 'verify', b.data.code)) return c.json(BAD_CODE, 400);
      db.setPassword(u.id, hash);
      db.markVerified(u.id);
      log('email_verified', { user_id: u.id });
      return c.json(issue(u.id, 'email'));
    });

    app.post('/v1/auth/email/login', ip, async (c) => {
      const { email, password } = EmailPassword.parse(await json(c));
      const key = emailKey(email);
      const wait = lockedFor(key);
      if (wait) return locked(c, wait);
      // The miss is counted before the slow hash, so many guesses at once still meet the lock after the fifth.
      failed(key);
      const u = db.userByEmailHash(key);
      const ok = await verifyPassword(password, u?.password_hash ?? (await dummyHash()));
      // An account still waiting for its code answers like a wrong password, so sign-in never tells a new email from a known one.
      if (!u || !u.password_hash || !ok || !u.email_verified_at) {
        log('email_login_failed', {});
        return c.json(WRONG, 401);
      }
      db.clearFailures(key);
      log('email_login', { user_id: u.id });
      return c.json(issue(u.id, 'email'));
    });

    app.post('/v1/auth/password/forgot', ip, async (c) => {
      const { email } = z.object({ email: Email }).strict().parse(await json(c));
      const key = emailKey(email);
      const u = db.userByEmailHash(key);
      if (u?.password_hash) mail(key, email, 'reset', () => newCode(u.id, 'reset'));
      else codeHash('none', 'reset', '000000');
      return c.json(CHECK_EMAIL, 202);
    });

    // A good reset code sets the password, confirms the email (the code came through it), ends every other session
    // and clears the lockout.
    app.post('/v1/auth/password/reset', ip, async (c) => {
      const b = z.object({ email: Email, code: Code, password: Password }).strict().safeParse(await json(c));
      if (!b.success) return c.json(BAD_CODE, 400);
      const problem = passwordProblem(b.data.password, b.data.email);
      if (problem) return c.json({ error: problem }, 400);
      const key = emailKey(b.data.email);
      const u = db.userByEmailHash(key);
      if (!u || !useCode(u.id, 'reset', b.data.code)) return c.json(BAD_CODE, 400);
      db.setPassword(u.id, await hashPassword(b.data.password));
      db.markVerified(u.id);
      db.deleteAllSessions(u.id);
      db.clearFailures(key);
      log('password_reset', { user_id: u.id });
      return c.json(issue(u.id, 'email'));
    });

    // Rotation: the refresh token is spent and a new pair comes back in the same session.
    // A spent token coming back means two holders: the session and every token in it are deleted.
    app.post('/v1/auth/refresh', rateLimiter('refresh', clientIp), async (c) => {
      const b = z.object({ refresh_token: z.string().regex(/^prt_[A-Za-z0-9_-]{20,100}$/) }).strict().safeParse(await c.req.json().catch(() => null));
      if (!b.success) return c.json({ error: 'unauthorized' }, 401);
      const hash = sha256(b.data.refresh_token);
      const spent = db.spendRefreshToken(hash);
      if (spent === 'reuse') {
        const sessionId = db.sessionForRefreshHash(hash);
        if (sessionId) db.deleteSession(sessionId);
        log('refresh_reuse', { session_id: sessionId });
        return c.json({ error: 'unauthorized' }, 401);
      }
      if (!spent) return c.json({ error: 'unauthorized' }, 401);
      db.dropAccessTokens(spent.sessionId);
      db.purgeTokens();
      return c.json(issue(spent.userId, '', spent.sessionId));
    });
  }

  /** Routes behind the token check. */
  function privateRoutes(app: Hono<Env>) {
    // "Save with Apple". A device account whose Apple account already has a user (an earlier install) moves its drawings there,
    // is deleted, and gets a session for that user. A signed-in account never switches to another one: that is a 409.
    app.post('/v1/auth/apple/link', rateLimiter('auth', (c) => c.get('userId')), async (c) => {
      const userId = c.get('userId');
      let sub: string;
      try {
        sub = await apple(await c.req.json());
      } catch (e) {
        log('apple_link_rejected', { user_id: userId, reason: e instanceof z.ZodError ? 'bad body' : (e as Error).message });
        return c.json({ error: 'unauthorized' }, 401);
      }
      const me = db.user(userId)!;
      const linked = db.linkAppleSub(userId, cipher.lookupHash('apple-sub', sub));
      if (!linked) return c.json({ error: 'this account is already saved with another Apple account' }, 409);
      if (linked.owner === userId) {
        log('apple_link', { user_id: userId, recovered: false });
        return c.json({ linked: true, recovered: false });
      }
      if (!anonymous(me)) return c.json({ error: 'this Apple account belongs to another Pip account' }, 409);
      db.mergeInto(userId, linked.owner);
      log('apple_link', { user_id: linked.owner, recovered: true, from_user_id: userId });
      return c.json({ linked: true, recovered: true, ...issue(linked.owner, 'apple') });
    });

    // Add an email and password to this account (a device or Apple account). The code goes to the new email; the account
    // keeps its id, so nothing is lost. An email that belongs to someone else gets a note instead, and the reply is the same.
    app.post('/v1/auth/email/link', rateLimiter('emailAuth', (c) => c.get('userId')), async (c) => {
      const userId = c.get('userId');
      const { email, password } = EmailPassword.parse(await json(c));
      if (db.user(userId)!.email_hash) return c.json({ error: 'this account already has an email' }, 409);
      const problem = passwordProblem(password, email);
      if (problem) return c.json({ error: problem }, 400);
      const hash = await hashPassword(password);
      const key = emailKey(email);
      if (db.userByEmailHash(key)) {
        mail(key, email, 'exists');
      } else {
        mail(key, email, 'link', () => newCode(userId, 'link', { emailHash: key, emailEnc: cipher.encrypt(userId, email), passwordHash: hash }));
      }
      return c.json(CHECK_EMAIL, 202);
    });

    app.post('/v1/auth/email/link/verify', rateLimiter('emailAuth', (c) => c.get('userId')), async (c) => {
      const userId = c.get('userId');
      const b = z.object({ code: Code }).strict().safeParse(await json(c));
      const row = b.success ? useCode(userId, 'link', b.data.code) : undefined;
      if (!row || !row.email_hash || !row.email_enc || !row.password_hash) return c.json(BAD_CODE, 400);
      if (!db.setEmail(userId, row.email_hash, row.email_enc, row.password_hash)) return c.json(BAD_CODE, 400);
      log('email_link', { user_id: userId });
      return c.json({ linked: true });
    });

    // What the Account screen shows. The email is decrypted for its owner only.
    app.get('/v1/me', (c) => {
      const u = db.user(c.get('userId'))!;
      return c.json({
        ok: true,
        email: u.email_enc ? cipher.decrypt(u.id, u.email_enc) : null,
        email_verified: !!u.email_verified_at,
        apple: !!u.apple_sub_hash,
        password: !!u.password_hash,
        anonymous: anonymous(u),
      });
    });

    app.post('/v1/auth/logout', (c) => {
      db.deleteSession(c.get('sessionId'));
      log('logout', { user_id: c.get('userId') });
      return c.json({ ok: true });
    });

    app.post('/v1/auth/logout-all', (c) => {
      const n = db.deleteAllSessions(c.get('userId'));
      log('logout_all', { user_id: c.get('userId'), sessions: n });
      return c.json({ ok: true });
    });

    // Deletes the user and, by cascade, every row that belongs to them: sessions, tokens, codes, device tokens, drawings.
    // An account with a password must send it, so a stolen access token alone cannot delete the account.
    // Others send { confirm: true }. A wrong password counts toward the sign-in lockout.
    app.delete('/v1/account', async (c) => {
      const userId = c.get('userId');
      const u = db.user(userId)!;
      const b = z.object({ password: Password.optional(), confirm: z.literal(true).optional() }).strict().safeParse(await c.req.json().catch(() => null));
      if (!b.success || (!u.password_hash && !b.data.confirm)) return c.json({ error: 'confirm to delete your account' }, 400);
      if (u.password_hash) {
        const key = u.email_hash!;
        const wait = lockedFor(key);
        if (wait) return locked(c, wait);
        failed(key);
        if (!b.data.password || !(await verifyPassword(b.data.password, u.password_hash))) return c.json({ error: 'wrong password' }, 403);
      }
      if (u.email_hash) db.clearFailures(u.email_hash);
      db.clearFailures(`code:${userId}`);
      db.deleteUser(userId);
      log('account_deleted', { user_id: userId });
      return c.json({ deleted: true });
    });
  }

  /** The token check: a live access token, from a session that still exists. Sets userId and sessionId. */
  function requireUser(app: Hono<Env>) {
    app.use('/v1/*', async (c, next) => {
      const m = /^Bearer (pat_[A-Za-z0-9_-]{20,100})$/.exec(c.req.header('authorization') ?? '');
      const who = m ? db.accessFor(sha256(m[1])) : undefined;
      if (!who) return c.json({ error: 'unauthorized' }, 401);
      c.set('userId', who.userId);
      c.set('sessionId', who.sessionId);
      await next();
    });
  }

  return { issue, publicRoutes, privateRoutes, requireUser };
}
