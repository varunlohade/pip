import type { Db } from '../../db.ts';
import type { Token } from '../config.ts';
import type { Network } from '../network.ts';

export type PhoneStatus = 'pending' | 'built' | 'rejected' | 'expired' | 'sending' | 'sent' | 'failed' | 'outcome_unknown';
export type PhoneIntent = {
  id: string; user_id: string; network: Network; token: Token; amount: string; units: string; recipient: string; status: PhoneStatus;
  new_recipient: number; created_at: number; expires_at: number; decided_at: number | null;
  tx_b64: string | null; tx_hash: string | null; nonce: string | null; public_key: string | null;
};
export type PhoneAccount = { user_id: string; network: Network; account_id: string; public_key: string; status: 'funding' | 'ready' | 'failed'; fund_tx: string | null };

/**
 * Tables for the phone-signed flow. The server keeps public keys and the exact unsigned bytes it built; never a private key.
 * Audit rows go to the existing append-only pay_audit table.
 */
export function openPhoneStore(db: Db, now: () => number) {
  db.raw.exec(`
CREATE TABLE IF NOT EXISTS pay_phone_accounts (
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE, network TEXT NOT NULL, account_id TEXT NOT NULL, public_key TEXT NOT NULL,
  status TEXT NOT NULL, fund_tx TEXT, created_at INTEGER NOT NULL, PRIMARY KEY (user_id, network), UNIQUE (network, account_id));
CREATE TABLE IF NOT EXISTS pay_phone_intents (
  id TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE, network TEXT NOT NULL, token TEXT NOT NULL,
  amount TEXT NOT NULL, units TEXT NOT NULL, recipient TEXT NOT NULL, status TEXT NOT NULL, new_recipient INTEGER NOT NULL,
  created_at INTEGER NOT NULL, expires_at INTEGER NOT NULL, decided_at INTEGER, tx_b64 TEXT, tx_hash TEXT, nonce TEXT, public_key TEXT);
CREATE INDEX IF NOT EXISTS pay_phone_intents_user ON pay_phone_intents(user_id, created_at);
CREATE TABLE IF NOT EXISTS pay_phone_recipients (
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE, network TEXT NOT NULL, recipient TEXT NOT NULL, added_at INTEGER NOT NULL,
  PRIMARY KEY (user_id, network, recipient));`);
  const q = (sql: string) => db.raw.prepare(sql);

  return {
    account(userId: string, network: Network): PhoneAccount | undefined {
      return q('SELECT user_id, network, account_id, public_key, status, fund_tx FROM pay_phone_accounts WHERE user_id = ? AND network = ?').get(userId, network) as PhoneAccount | undefined;
    },
    accountCount(network: Network): number {
      return (q("SELECT COUNT(*) AS n FROM pay_phone_accounts WHERE network = ? AND status != 'failed'").get(network) as { n: number }).n;
    },
    /** False when this user already has an account on the network, or another user holds this account id. */
    claimAccount(userId: string, network: Network, accountId: string, publicKey: string, status: PhoneAccount['status']): boolean {
      return q('INSERT INTO pay_phone_accounts (user_id, network, account_id, public_key, status, created_at) VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT DO NOTHING')
        .run(userId, network, accountId, publicKey, status, now()).changes > 0;
    },
    moveAccount(userId: string, network: Network, from: PhoneAccount['status'], to: PhoneAccount['status'], tx: string | null = null): boolean {
      return q('UPDATE pay_phone_accounts SET status = ?, fund_tx = COALESCE(?, fund_tx) WHERE user_id = ? AND network = ? AND status = ?')
        .run(to, tx, userId, network, from).changes > 0;
    },

    knownRecipient(userId: string, network: Network, recipient: string): boolean {
      return q('SELECT 1 FROM pay_phone_recipients WHERE user_id = ? AND network = ? AND recipient = ?').get(userId, network, recipient) !== undefined;
    },
    addRecipient(userId: string, network: Network, recipient: string) {
      q('INSERT INTO pay_phone_recipients (user_id, network, recipient, added_at) VALUES (?, ?, ?, ?) ON CONFLICT DO NOTHING').run(userId, network, recipient, now());
    },

    addIntent(i: Pick<PhoneIntent, 'id' | 'user_id' | 'network' | 'token' | 'amount' | 'units' | 'recipient' | 'new_recipient' | 'created_at' | 'expires_at'>) {
      q("INSERT INTO pay_phone_intents (id, user_id, network, token, amount, units, recipient, status, new_recipient, created_at, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?, 'pending', ?, ?, ?)")
        .run(i.id, i.user_id, i.network, i.token, i.amount, i.units, i.recipient, i.new_recipient, i.created_at, i.expires_at);
    },
    intent(id: string): PhoneIntent | undefined {
      return q('SELECT * FROM pay_phone_intents WHERE id = ?').get(id) as PhoneIntent | undefined;
    },
    history(userId: string, network: Network, limit: number): PhoneIntent[] {
      return q('SELECT * FROM pay_phone_intents WHERE user_id = ? AND network = ? ORDER BY created_at DESC, rowid DESC LIMIT ?').all(userId, network, limit) as PhoneIntent[];
    },
    /** Units that left, may have left, or sit in a live built tx since `since`. Unknown outcomes count, so a retry never passes a cap. */
    spentSince(userId: string, network: Network, token: Token, since: number): bigint {
      const rows = q(`SELECT units FROM pay_phone_intents WHERE user_id = ? AND network = ? AND token = ? AND decided_at >= ?
        AND (status IN ('sending', 'sent', 'outcome_unknown') OR (status = 'built' AND expires_at > ?))`).all(userId, network, token, since, now()) as { units: string }[];
      return rows.reduce((sum, r) => sum + BigInt(r.units), 0n);
    },
    /** The highest nonce this server built for a key, so two built txs never share one. */
    lastNonce(network: Network, publicKey: string): bigint {
      const rows = q('SELECT nonce FROM pay_phone_intents WHERE network = ? AND public_key = ? AND nonce IS NOT NULL').all(network, publicKey) as { nonce: string }[];
      return rows.reduce((max, r) => (BigInt(r.nonce) > max ? BigInt(r.nonce) : max), 0n);
    },
    /** Moves an intent on. Only one caller wins: the WHERE holds the status it expects. */
    move(id: string, from: PhoneStatus, to: PhoneStatus, extra: { decidedAt?: number; txB64?: string; txHash?: string; nonce?: string; publicKey?: string } = {}): boolean {
      return q(`UPDATE pay_phone_intents SET status = ?, decided_at = COALESCE(?, decided_at), tx_b64 = COALESCE(?, tx_b64), tx_hash = COALESCE(?, tx_hash),
        nonce = COALESCE(?, nonce), public_key = COALESCE(?, public_key) WHERE id = ? AND status = ?`)
        .run(to, extra.decidedAt ?? null, extra.txB64 ?? null, extra.txHash ?? null, extra.nonce ?? null, extra.publicKey ?? null, id, from).changes > 0;
    },
  };
}

export type PhoneStore = ReturnType<typeof openPhoneStore>;
