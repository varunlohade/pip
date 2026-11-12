import { DatabaseSync } from 'node:sqlite';
import { mkdirSync } from 'node:fs';
import { dirname } from 'node:path';
import { randomUUID } from 'node:crypto';

/**
 * Migrations, in order. PRAGMA user_version holds how many have run. Never edit one that shipped; add a new one.
 * 1: the first schema (databases made before migrations are at version 0 and already have most of it).
 * 2: every per-user table cascades on user delete; email + password columns; sessions, refresh and access tokens,
 *    emailed codes and login failures.
 */
const MIGRATIONS: ((db: DatabaseSync) => void)[] = [
  (db) => {
    db.exec(`
CREATE TABLE IF NOT EXISTS users (id TEXT PRIMARY KEY, created_at INTEGER NOT NULL, apple_sub_hash TEXT);
CREATE UNIQUE INDEX IF NOT EXISTS users_apple ON users(apple_sub_hash) WHERE apple_sub_hash IS NOT NULL;
CREATE TABLE IF NOT EXISTS devices (
  token_hash TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id), label TEXT, created_at INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS shared_images (
  id TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id), png BLOB NOT NULL, created_at INTEGER NOT NULL, expires_at INTEGER NOT NULL,
  preview BLOB, preview_w INTEGER, preview_h INTEGER, title TEXT);
CREATE INDEX IF NOT EXISTS shared_images_expiry ON shared_images(expires_at);`);
    // Databases made before link previews lack the preview columns.
    const cols = new Set((db.prepare('PRAGMA table_info(shared_images)').all() as { name: string }[]).map((c) => c.name));
    for (const [name, type] of [['preview', 'BLOB'], ['preview_w', 'INTEGER'], ['preview_h', 'INTEGER'], ['title', 'TEXT']]) {
      if (!cols.has(name)) db.exec(`ALTER TABLE shared_images ADD COLUMN ${name} ${type}`);
    }
  },
  (db) => {
    db.exec(`
ALTER TABLE users ADD COLUMN email_hash TEXT;
ALTER TABLE users ADD COLUMN email_enc TEXT;
ALTER TABLE users ADD COLUMN email_verified_at INTEGER;
ALTER TABLE users ADD COLUMN password_hash TEXT;
CREATE UNIQUE INDEX users_email ON users(email_hash) WHERE email_hash IS NOT NULL;

CREATE TABLE devices_v2 (
  token_hash TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE, label TEXT, created_at INTEGER NOT NULL);
INSERT INTO devices_v2 SELECT token_hash, user_id, label, created_at FROM devices;
DROP TABLE devices;
ALTER TABLE devices_v2 RENAME TO devices;
CREATE INDEX devices_user ON devices(user_id);

CREATE TABLE shared_images_v2 (
  id TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE, png BLOB NOT NULL, created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL, preview BLOB, preview_w INTEGER, preview_h INTEGER, title TEXT);
INSERT INTO shared_images_v2 SELECT id, user_id, png, created_at, expires_at, preview, preview_w, preview_h, title FROM shared_images;
DROP TABLE shared_images;
ALTER TABLE shared_images_v2 RENAME TO shared_images;
CREATE INDEX shared_images_expiry ON shared_images(expires_at);
CREATE INDEX shared_images_user ON shared_images(user_id);

-- One sign-in on one phone. Its refresh tokens are one family: logout or a reused refresh token deletes the session and all of them.
CREATE TABLE sessions (
  id TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE, label TEXT, created_at INTEGER NOT NULL);
CREATE INDEX sessions_user ON sessions(user_id);
CREATE TABLE refresh_tokens (
  token_hash TEXT PRIMARY KEY, session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  created_at INTEGER NOT NULL, expires_at INTEGER NOT NULL, used_at INTEGER);
CREATE INDEX refresh_tokens_session ON refresh_tokens(session_id);
CREATE TABLE access_tokens (
  token_hash TEXT PRIMARY KEY, session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE, expires_at INTEGER NOT NULL);
CREATE INDEX access_tokens_session ON access_tokens(session_id);

-- One live code per user and purpose. 'link' also holds the email and password waiting to be added.
CREATE TABLE email_codes (
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE, purpose TEXT NOT NULL, code_hash TEXT NOT NULL,
  expires_at INTEGER NOT NULL, attempts INTEGER NOT NULL DEFAULT 0, email_hash TEXT, email_enc TEXT, password_hash TEXT,
  PRIMARY KEY (user_id, purpose));

-- Failed password sign-ins per email hash, for known and unknown emails alike, so a lockout says nothing about an account.
CREATE TABLE login_failures (key TEXT PRIMARY KEY, count INTEGER NOT NULL, locked_until INTEGER NOT NULL, last_at INTEGER NOT NULL);`);
  },
];

function migrate(db: DatabaseSync) {
  db.exec('PRAGMA journal_mode = WAL');
  const version = (db.prepare('PRAGMA user_version').get() as { user_version: number }).user_version;
  for (let v = version; v < MIGRATIONS.length; v++) {
    // Table rebuilds need foreign keys off; the check after each step proves no row lost its parent.
    db.exec('PRAGMA foreign_keys = OFF');
    db.exec('BEGIN');
    try {
      MIGRATIONS[v](db);
      if ((db.prepare('PRAGMA foreign_key_check').all() as unknown[]).length) throw new Error(`migration ${v + 1}: foreign key check failed`);
      db.exec(`PRAGMA user_version = ${v + 1}`);
      db.exec('COMMIT');
    } catch (e) {
      db.exec('ROLLBACK');
      throw e;
    } finally {
      db.exec('PRAGMA foreign_keys = ON');
    }
  }
}

export const SCHEMA_VERSION = MIGRATIONS.length;

export type Db = ReturnType<typeof openDb>;
export type Preview = { jpeg: Uint8Array; width: number; height: number };
export type SharedImage = { png: Uint8Array; expiresAt: number; preview?: Preview; title?: string };
export type SharedImageInput = { id: string; userId: string; png: Uint8Array; createdAt: number; expiresAt: number; preview?: Preview; title?: string };
export type UserRow = {
  id: string; apple_sub_hash: string | null; email_hash: string | null; email_enc: string | null;
  email_verified_at: number | null; password_hash: string | null;
};
export type CodeRow = { user_id: string; purpose: string; code_hash: string; expires_at: number; attempts: number; email_hash: string | null; email_enc: string | null; password_hash: string | null };
export type CodePurpose = 'verify' | 'reset' | 'link';

export function openDb(path: string, o: { now?: () => number } = {}) {
  if (path !== ':memory:') mkdirSync(dirname(path), { recursive: true });
  const db = new DatabaseSync(path);
  migrate(db);
  db.exec('PRAGMA foreign_keys = ON');
  const now = o.now ?? Date.now;
  const q = (sql: string) => db.prepare(sql);
  const tx = <T>(fn: () => T): T => {
    db.exec('BEGIN IMMEDIATE');
    try {
      const out = fn();
      db.exec('COMMIT');
      return out;
    } catch (e) {
      db.exec('ROLLBACK');
      throw e;
    }
  };

  return {
    raw: db,
    tx,

    createUser(): string {
      const id = randomUUID();
      q('INSERT INTO users (id, created_at) VALUES (?, ?)').run(id, now());
      return id;
    },
    user(id: string): UserRow | undefined {
      return q('SELECT id, apple_sub_hash, email_hash, email_enc, email_verified_at, password_hash FROM users WHERE id = ?').get(id) as UserRow | undefined;
    },
    userByEmailHash(emailHash: string): UserRow | undefined {
      return q('SELECT id, apple_sub_hash, email_hash, email_enc, email_verified_at, password_hash FROM users WHERE email_hash = ?').get(emailHash) as UserRow | undefined;
    },
    /** A new email account, not verified yet. The email is stored only as its keyed hash and its encrypted form. */
    createEmailUser(emailHash: string, emailEnc: (userId: string) => string, passwordHash: string): string {
      const id = randomUUID();
      q('INSERT INTO users (id, created_at, email_hash, email_enc, password_hash) VALUES (?, ?, ?, ?, ?)').run(id, now(), emailHash, emailEnc(id), passwordHash);
      return id;
    },
    setPassword(userId: string, passwordHash: string) {
      q('UPDATE users SET password_hash = ? WHERE id = ?').run(passwordHash, userId);
    },
    markVerified(userId: string) {
      q('UPDATE users SET email_verified_at = COALESCE(email_verified_at, ?) WHERE id = ?').run(now(), userId);
    },
    /** Adds a verified email and password to a user who has none. False when another user took the email meanwhile. */
    setEmail(userId: string, emailHash: string, emailEnc: string, passwordHash: string): boolean {
      try {
        return q('UPDATE users SET email_hash = ?, email_enc = ?, password_hash = ?, email_verified_at = ? WHERE id = ? AND email_hash IS NULL')
          .run(emailHash, emailEnc, passwordHash, now(), userId).changes > 0;
      } catch {
        return false;
      }
    },
    // Atomic find-or-create, so two sign-ins at once for one Apple account end with one user.
    userForAppleSub(subHash: string): { userId: string; created: boolean } {
      const id = randomUUID();
      const created = q('INSERT OR IGNORE INTO users (id, created_at, apple_sub_hash) VALUES (?, ?, ?)').run(id, now(), subHash).changes > 0;
      if (created) return { userId: id, created };
      return { userId: (q('SELECT id FROM users WHERE apple_sub_hash = ?').get(subHash) as { id: string }).id, created };
    },
    /**
     * Attaches an Apple account to a user. `owner` is the user that holds this Apple account afterwards: this user, or the
     * earlier user it already belonged to. Null when this user is saved under another Apple account.
     */
    linkAppleSub(userId: string, subHash: string): { owner: string } | null {
      const find = () => q('SELECT id FROM users WHERE apple_sub_hash = ?').get(subHash) as { id: string } | undefined;
      const held = find();
      if (held) return { owner: held.id };
      try {
        // The unique index settles two links at once: one wins, the other reads the winner.
        if (q('UPDATE users SET apple_sub_hash = ? WHERE id = ? AND apple_sub_hash IS NULL').run(subHash, userId).changes > 0) return { owner: userId };
      } catch {}
      const winner = find();
      return winner ? { owner: winner.id } : null;
    },
    /** A device account found its earlier Apple account: its drawings move there, then it is deleted. */
    mergeInto(fromUserId: string, toUserId: string) {
      tx(() => {
        q('UPDATE shared_images SET user_id = ? WHERE user_id = ?').run(toUserId, fromUserId);
        q('DELETE FROM users WHERE id = ?').run(fromUserId);
      });
    },
    /** Deletes the user. Every per-user table cascades: sessions, tokens, codes, devices, drawings. */
    deleteUser(userId: string): boolean {
      return q('DELETE FROM users WHERE id = ?').run(userId).changes > 0;
    },

    // ---- legacy device tokens (before sessions). Only /v1/auth/device/exchange reads them, once.
    addDevice(userId: string, tokenHash: string, label: string | null) {
      q('INSERT INTO devices (token_hash, user_id, label, created_at) VALUES (?, ?, ?, ?)').run(tokenHash, userId, label, now());
    },
    takeDevice(tokenHash: string): string | undefined {
      const r = q('DELETE FROM devices WHERE token_hash = ? RETURNING user_id').get(tokenHash) as { user_id: string } | undefined;
      return r?.user_id;
    },

    // ---- sessions
    createSession(userId: string, label: string): string {
      const id = randomUUID();
      q('INSERT INTO sessions (id, user_id, label, created_at) VALUES (?, ?, ?, ?)').run(id, userId, label, now());
      return id;
    },
    addRefreshToken(sessionId: string, tokenHash: string, expiresAt: number) {
      q('INSERT INTO refresh_tokens (token_hash, session_id, created_at, expires_at) VALUES (?, ?, ?, ?)').run(tokenHash, sessionId, now(), expiresAt);
    },
    addAccessToken(sessionId: string, tokenHash: string, expiresAt: number) {
      q('INSERT INTO access_tokens (token_hash, session_id, expires_at) VALUES (?, ?, ?)').run(tokenHash, sessionId, expiresAt);
    },
    /**
     * Spends a refresh token. 'reuse' means it was spent before: the caller deletes the whole session.
     * The UPDATE ... WHERE used_at IS NULL makes two refreshes with one token end with one winner.
     */
    spendRefreshToken(tokenHash: string): { sessionId: string; userId: string } | 'reuse' | undefined {
      const r = q('SELECT r.session_id, r.expires_at, r.used_at, s.user_id FROM refresh_tokens r JOIN sessions s ON s.id = r.session_id WHERE r.token_hash = ?')
        .get(tokenHash) as { session_id: string; expires_at: number; used_at: number | null; user_id: string } | undefined;
      if (!r) return undefined;
      if (r.used_at !== null) return 'reuse';
      if (r.expires_at <= now()) return undefined;
      if (q('UPDATE refresh_tokens SET used_at = ? WHERE token_hash = ? AND used_at IS NULL').run(now(), tokenHash).changes === 0) return 'reuse';
      return { sessionId: r.session_id, userId: r.user_id };
    },
    sessionForRefreshHash(tokenHash: string): string | undefined {
      return (q('SELECT session_id FROM refresh_tokens WHERE token_hash = ?').get(tokenHash) as { session_id: string } | undefined)?.session_id;
    },
    /** Old access tokens of a session go when it refreshes, so a stolen one dies with the next rotation. */
    dropAccessTokens(sessionId: string) {
      q('DELETE FROM access_tokens WHERE session_id = ?').run(sessionId);
    },
    accessFor(tokenHash: string): { userId: string; sessionId: string } | undefined {
      const r = q('SELECT a.session_id, s.user_id FROM access_tokens a JOIN sessions s ON s.id = a.session_id WHERE a.token_hash = ? AND a.expires_at > ?')
        .get(tokenHash, now()) as { session_id: string; user_id: string } | undefined;
      return r && { userId: r.user_id, sessionId: r.session_id };
    },
    deleteSession(sessionId: string) {
      q('DELETE FROM sessions WHERE id = ?').run(sessionId);
    },
    /** "Log out everywhere": every session and every legacy device token of the user. */
    deleteAllSessions(userId: string): number {
      q('DELETE FROM devices WHERE user_id = ?').run(userId);
      return Number(q('DELETE FROM sessions WHERE user_id = ?').run(userId).changes);
    },
    sessionCount(userId: string): number {
      return (q('SELECT COUNT(*) AS n FROM sessions WHERE user_id = ?').get(userId) as { n: number }).n;
    },
    purgeTokens() {
      const at = now();
      q('DELETE FROM access_tokens WHERE expires_at <= ?').run(at);
      // A spent refresh token is kept until it expires, so its reuse is still caught.
      q('DELETE FROM refresh_tokens WHERE expires_at <= ?').run(at);
      q('DELETE FROM sessions WHERE NOT EXISTS (SELECT 1 FROM refresh_tokens r WHERE r.session_id = sessions.id)').run();
      q('DELETE FROM email_codes WHERE expires_at <= ?').run(at);
    },

    // ---- emailed codes
    putCode(c: { userId: string; purpose: CodePurpose; codeHash: string; expiresAt: number; emailHash?: string; emailEnc?: string; passwordHash?: string }) {
      q(`INSERT INTO email_codes (user_id, purpose, code_hash, expires_at, attempts, email_hash, email_enc, password_hash) VALUES (?, ?, ?, ?, 0, ?, ?, ?)
         ON CONFLICT (user_id, purpose) DO UPDATE SET code_hash = excluded.code_hash, expires_at = excluded.expires_at, attempts = 0,
         email_hash = excluded.email_hash, email_enc = excluded.email_enc, password_hash = excluded.password_hash`)
        .run(c.userId, c.purpose, c.codeHash, c.expiresAt, c.emailHash ?? null, c.emailEnc ?? null, c.passwordHash ?? null);
    },
    code(userId: string, purpose: CodePurpose): CodeRow | undefined {
      return q('SELECT * FROM email_codes WHERE user_id = ? AND purpose = ?').get(userId, purpose) as CodeRow | undefined;
    },
    codeAttempt(userId: string, purpose: CodePurpose) {
      q('UPDATE email_codes SET attempts = attempts + 1 WHERE user_id = ? AND purpose = ?').run(userId, purpose);
    },
    deleteCode(userId: string, purpose: CodePurpose) {
      q('DELETE FROM email_codes WHERE user_id = ? AND purpose = ?').run(userId, purpose);
    },

    // ---- login failures, keyed by the email hash
    failures(key: string): { count: number; locked_until: number; last_at: number } | undefined {
      return q('SELECT count, locked_until, last_at FROM login_failures WHERE key = ?').get(key) as { count: number; locked_until: number; last_at: number } | undefined;
    },
    setFailures(key: string, count: number, lockedUntil: number) {
      q('INSERT INTO login_failures (key, count, locked_until, last_at) VALUES (?, ?, ?, ?) ON CONFLICT (key) DO UPDATE SET count = excluded.count, locked_until = excluded.locked_until, last_at = excluded.last_at')
        .run(key, count, lockedUntil, now());
    },
    clearFailures(key: string) {
      q('DELETE FROM login_failures WHERE key = ?').run(key);
    },

    // A drawing shared as a link. The id is the only way to reach it; no query lists them.
    addSharedImage(img: SharedImageInput) {
      q('INSERT INTO shared_images (id, user_id, png, created_at, expires_at, preview, preview_w, preview_h, title) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)')
        .run(img.id, img.userId, img.png, img.createdAt, img.expiresAt, img.preview?.jpeg ?? null, img.preview?.width ?? null, img.preview?.height ?? null, img.title ?? null);
    },
    /** A live drawing, 'gone' once it expired (the row stays, emptied, so its link can say so), or undefined for an unknown id. */
    sharedImage(id: string, at: number): SharedImage | 'gone' | undefined {
      const r = q('SELECT png, expires_at, preview, preview_w, preview_h, title FROM shared_images WHERE id = ?').get(id) as
        { png: Uint8Array; expires_at: number; preview: Uint8Array | null; preview_w: number | null; preview_h: number | null; title: string | null } | undefined;
      if (!r) return undefined;
      if (r.expires_at <= at) return 'gone';
      const preview = r.preview && r.preview_w && r.preview_h ? { jpeg: r.preview, width: r.preview_w, height: r.preview_h } : undefined;
      return { png: r.png, expiresAt: r.expires_at, preview, title: r.title ?? undefined };
    },
    /** Empties expired drawings and deletes their rows after `keepGoneMs` more. Returns how many images it emptied. */
    purgeSharedImages(at: number, keepGoneMs: number): number {
      q('DELETE FROM shared_images WHERE expires_at <= ?').run(at - keepGoneMs);
      return Number(q("UPDATE shared_images SET png = x'', preview = NULL, title = NULL WHERE expires_at <= ? AND length(png) > 0").run(at).changes);
    },
  };
}
