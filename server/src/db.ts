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
  id TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id), png BLOB NOT NULL, created_at INTEGER NOT NULL, expires_at INTEGER NOT NULL,
  preview BLOB, preview_w INTEGER, preview_h INTEGER, title TEXT);
CREATE INDEX IF NOT EXISTS shared_images_expiry ON shared_images(expires_at);
`;

export type Db = ReturnType<typeof openDb>;
export type Preview = { jpeg: Uint8Array; width: number; height: number };
export type SharedImage = { png: Uint8Array; expiresAt: number; preview?: Preview; title?: string };
export type SharedImageInput = { id: string; userId: string; png: Uint8Array; createdAt: number; expiresAt: number; preview?: Preview; title?: string };

export function openDb(path: string) {
  if (path !== ':memory:') mkdirSync(dirname(path), { recursive: true });
  const db = new DatabaseSync(path);
  db.exec(SCHEMA);
  // Databases made before link previews lack the preview columns.
  const cols = new Set((db.prepare('PRAGMA table_info(shared_images)').all() as { name: string }[]).map((c) => c.name));
  for (const [name, type] of [['preview', 'BLOB'], ['preview_w', 'INTEGER'], ['preview_h', 'INTEGER'], ['title', 'TEXT']]) {
    if (!cols.has(name)) db.exec(`ALTER TABLE shared_images ADD COLUMN ${name} ${type}`);
  }
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
    userForTokenHash(tokenHash: string): string | undefined {
      const r = q('SELECT user_id FROM devices WHERE token_hash = ?').get(tokenHash) as { user_id: string } | undefined;
      return r?.user_id;
    },
  };
}
