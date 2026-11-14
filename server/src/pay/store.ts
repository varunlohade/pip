import type { Db } from '../db.ts';
import type { Token } from './config.ts';

export type IntentStatus = 'pending' | 'rejected' | 'expired' | 'sending' | 'sent' | 'failed' | 'outcome_unknown';
export type Intent = {
  id: string; user_id: string; token: Token; amount: string; units: string; recipient: string; status: IntentStatus;
  created_at: number; expires_at: number; decided_at: number | null; tx_hash: string | null;
  /** Who approved it: 'app' (approver key) or 'keyboard' (the capped keyboard key). Null until approved. */
  via: 'app' | 'keyboard' | null;
};
export type KeyboardPay = { key_hash: string; usdc_daily: string; near_daily: string };
export type Wallet = { user_id: string; account_id: string; key_enc: string; status: 'creating' | 'ready' | 'failed'; create_tx: string | null };

/**
 * Payment tables on the main database. They sit outside db.ts migrations so the pay feature stays in its own files;
 * every table cascades on user delete like the rest. The audit table is append-only.
 */
export function openPayStore(db: Db, now: () => number) {
  db.raw.exec(`
CREATE TABLE IF NOT EXISTS pay_wallets (
  user_id TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE, account_id TEXT NOT NULL UNIQUE, key_enc TEXT NOT NULL,
  status TEXT NOT NULL, create_tx TEXT, created_at INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS pay_approvers (
  user_id TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE, key_hash TEXT NOT NULL, session_id TEXT NOT NULL, created_at INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS pay_intents (
  id TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE, token TEXT NOT NULL, amount TEXT NOT NULL,
  units TEXT NOT NULL, recipient TEXT NOT NULL, status TEXT NOT NULL, created_at INTEGER NOT NULL, expires_at INTEGER NOT NULL,
  decided_at INTEGER, tx_hash TEXT);
CREATE INDEX IF NOT EXISTS pay_intents_user ON pay_intents(user_id, created_at);
CREATE TABLE IF NOT EXISTS pay_audit (
  id INTEGER PRIMARY KEY AUTOINCREMENT, user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE, intent_id TEXT, event TEXT NOT NULL, at INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS pay_keyboard (
  user_id TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE, key_hash TEXT NOT NULL, usdc_daily TEXT NOT NULL, near_daily TEXT NOT NULL,
  created_at INTEGER NOT NULL);
CREATE TRIGGER IF NOT EXISTS pay_audit_no_update BEFORE UPDATE ON pay_audit BEGIN SELECT RAISE(ABORT, 'pay_audit is append-only'); END;`);
  if (!(db.raw.prepare('PRAGMA table_info(pay_intents)').all() as { name: string }[]).some((c) => c.name === 'via')) {
    db.raw.exec('ALTER TABLE pay_intents ADD COLUMN via TEXT');
  }
  const q = (sql: string) => db.raw.prepare(sql);
  const audit = (userId: string, intentId: string | null, event: string) =>
    q('INSERT INTO pay_audit (user_id, intent_id, event, at) VALUES (?, ?, ?, ?)').run(userId, intentId, event, now());

  return {
    audit,
    wallet(userId: string): Wallet | undefined {
      return q('SELECT user_id, account_id, key_enc, status, create_tx FROM pay_wallets WHERE user_id = ?').get(userId) as Wallet | undefined;
    },
    walletCount(): number {
      return (q("SELECT COUNT(*) AS n FROM pay_wallets WHERE status != 'failed'").get() as { n: number }).n;
    },
    /** Claims the wallet row. False when one already exists, so two calls never create two accounts. */
    claimWallet(userId: string, accountId: string, keyEnc: string): boolean {
      return q("INSERT INTO pay_wallets (user_id, account_id, key_enc, status, created_at) VALUES (?, ?, ?, 'creating', ?) ON CONFLICT DO NOTHING")
        .run(userId, accountId, keyEnc, now()).changes > 0;
    },
    finishWallet(userId: string, status: 'ready' | 'failed', tx: string | null) {
      q('UPDATE pay_wallets SET status = ?, create_tx = ? WHERE user_id = ?').run(status, tx, userId);
    },
    dropFailedWallet(userId: string) {
      q("DELETE FROM pay_wallets WHERE user_id = ? AND status = 'failed'").run(userId);
    },

    approver(userId: string): { key_hash: string; session_id: string } | undefined {
      return q('SELECT key_hash, session_id FROM pay_approvers WHERE user_id = ?').get(userId) as { key_hash: string; session_id: string } | undefined;
    },
    setApprover(userId: string, keyHash: string, sessionId: string) {
      q('INSERT INTO pay_approvers (user_id, key_hash, session_id, created_at) VALUES (?, ?, ?, ?) ON CONFLICT(user_id) DO UPDATE SET key_hash = excluded.key_hash, session_id = excluded.session_id, created_at = excluded.created_at')
        .run(userId, keyHash, sessionId, now());
    },
    sessionAlive(sessionId: string): boolean {
      return q('SELECT 1 FROM sessions WHERE id = ?').get(sessionId) !== undefined;
    },

    /** The keyboard send key: its hash and the owner's daily limits, in base units. Set only with the approver key. */
    keyboard(userId: string): KeyboardPay | undefined {
      return q('SELECT key_hash, usdc_daily, near_daily FROM pay_keyboard WHERE user_id = ?').get(userId) as KeyboardPay | undefined;
    },
    setKeyboard(userId: string, keyHash: string, usdcDaily: bigint, nearDaily: bigint) {
      q('INSERT INTO pay_keyboard (user_id, key_hash, usdc_daily, near_daily, created_at) VALUES (?, ?, ?, ?, ?) ON CONFLICT(user_id) DO UPDATE SET key_hash = excluded.key_hash, usdc_daily = excluded.usdc_daily, near_daily = excluded.near_daily, created_at = excluded.created_at')
        .run(userId, keyHash, usdcDaily.toString(), nearDaily.toString(), now());
    },
    dropKeyboard(userId: string) {
      q('DELETE FROM pay_keyboard WHERE user_id = ?').run(userId);
    },
    /** Sends to this recipient that went through before. A new recipient has none, so the keyboard cannot pay it. */
    paidBefore(userId: string, recipient: string): number {
      return (q("SELECT COUNT(*) AS n FROM pay_intents WHERE user_id = ? AND recipient = ? AND status = 'sent'").get(userId, recipient) as { n: number }).n;
    },
    /** Like spentSince, for keyboard-approved sends only. */
    keyboardSpentSince(userId: string, token: Token, since: number): bigint {
      const rows = q("SELECT units FROM pay_intents WHERE user_id = ? AND token = ? AND via = 'keyboard' AND status IN ('sending', 'sent', 'outcome_unknown') AND decided_at >= ?")
        .all(userId, token, since) as { units: string }[];
      return rows.reduce((sum, r) => sum + BigInt(r.units), 0n);
    },

    addIntent(i: Omit<Intent, 'status' | 'decided_at' | 'tx_hash' | 'via'>) {
      q("INSERT INTO pay_intents (id, user_id, token, amount, units, recipient, status, created_at, expires_at) VALUES (?, ?, ?, ?, ?, ?, 'pending', ?, ?)")
        .run(i.id, i.user_id, i.token, i.amount, i.units, i.recipient, i.created_at, i.expires_at);
    },
    intent(id: string): Intent | undefined {
      return q('SELECT * FROM pay_intents WHERE id = ?').get(id) as Intent | undefined;
    },
    history(userId: string, limit: number): Intent[] {
      return q('SELECT * FROM pay_intents WHERE user_id = ? ORDER BY created_at DESC, rowid DESC LIMIT ?').all(userId, limit) as Intent[];
    },
    /** Base units that left, or may have left, since `since`. Unknown outcomes count, so a cap is never passed by a retry. */
    spentSince(userId: string, token: Token, since: number): bigint {
      const rows = q("SELECT units FROM pay_intents WHERE user_id = ? AND token = ? AND status IN ('sending', 'sent', 'outcome_unknown') AND decided_at >= ?")
        .all(userId, token, since) as { units: string }[];
      return rows.reduce((sum, r) => sum + BigInt(r.units), 0n);
    },
    /** Moves a pending intent on. Only one caller can win: the WHERE holds the status it expects. */
    move(id: string, from: IntentStatus, to: IntentStatus, extra: { decidedAt?: number; txHash?: string; via?: 'app' | 'keyboard' } = {}): boolean {
      return q('UPDATE pay_intents SET status = ?, decided_at = COALESCE(?, decided_at), tx_hash = COALESCE(?, tx_hash), via = COALESCE(?, via) WHERE id = ? AND status = ?')
        .run(to, extra.decidedAt ?? null, extra.txHash ?? null, extra.via ?? null, id, from).changes > 0;
    },
  };
}

export type PayStore = ReturnType<typeof openPayStore>;
