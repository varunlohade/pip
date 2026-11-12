import { DatabaseSync } from 'node:sqlite';
import { mkdirSync } from 'node:fs';
import { dirname } from 'node:path';
import { randomUUID } from 'node:crypto';

const SCHEMA = `
PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;
CREATE TABLE IF NOT EXISTS users (id TEXT PRIMARY KEY, created_at INTEGER NOT NULL, apple_sub_hash TEXT);
CREATE UNIQUE INDEX IF NOT EXISTS users_apple ON users(apple_sub_hash) WHERE apple_sub_hash IS NOT NULL;
CREATE TABLE IF NOT EXISTS devices (
  token_hash TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id), label TEXT, created_at INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS shared_images (
  id TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id), png BLOB NOT NULL, created_at INTEGER NOT NULL, expires_at INTEGER NOT NULL);
CREATE INDEX IF NOT EXISTS shared_images_expiry ON shared_images(expires_at);
`;

export type Db = ReturnType<typeof openDb>;

export function openDb(path: string) {
  if (path !== ':memory:') mkdirSync(dirname(path), { recursive: true });
  const db = new DatabaseSync(path);
  db.exec(SCHEMA);
  const now = () => Date.now();
  const q = (sql: string) => db.prepare(sql);

  return {
    raw: db,

    createUser(): string {
      const id = randomUUID();
      q('INSERT INTO users (id, created_at) VALUES (?, ?)').run(id, now());
      return id;
    },
    // Atomic find-or-create, so two sign-ins at once for one Apple account end with one user.
    userForAppleSub(subHash: string): { userId: string; created: boolean } {
      const id = randomUUID();
      const created = q('INSERT OR IGNORE INTO users (id, created_at, apple_sub_hash) VALUES (?, ?, ?)').run(id, now(), subHash).changes > 0;
      if (created) return { userId: id, created };
      return { userId: (q('SELECT id FROM users WHERE apple_sub_hash = ?').get(subHash) as { id: string }).id, created };
    },
    /**
     * Attaches an Apple account to a user who started with a device account. `owner` is the user that holds this Apple
     * account afterwards: this user, or the earlier user it already belonged to. Null when this user is saved under another Apple account.
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
    addDevice(userId: string, tokenHash: string, label: string | null) {
      q('INSERT INTO devices (token_hash, user_id, label, created_at) VALUES (?, ?, ?, ?)').run(tokenHash, userId, label, now());
    },
    // A drawing shared as a link. The id is the only way to reach it; no query lists them.
    addSharedImage(id: string, userId: string, png: Uint8Array, createdAt: number, expiresAt: number) {
      q('INSERT INTO shared_images (id, user_id, png, created_at, expires_at) VALUES (?, ?, ?, ?, ?)').run(id, userId, png, createdAt, expiresAt);
    },
    sharedImage(id: string, at: number): Uint8Array | undefined {
      const r = q('SELECT png FROM shared_images WHERE id = ? AND expires_at > ?').get(id, at) as { png: Uint8Array } | undefined;
      return r?.png;
    },
    purgeSharedImages(at: number): number {
      return Number(q('DELETE FROM shared_images WHERE expires_at <= ?').run(at).changes);
    },
    userForTokenHash(tokenHash: string): string | undefined {
      const r = q('SELECT user_id FROM devices WHERE token_hash = ?').get(tokenHash) as { user_id: string } | undefined;
      return r?.user_id;
    },
  };
}
