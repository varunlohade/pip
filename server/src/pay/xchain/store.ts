import type { Db } from '../../db.ts';

export type XchainRow = {
  intent_id: string; user_id: string; origin_asset: string; dest_asset: string; dest_chain: string; dest_recipient: string;
  deposit_address: string; refund_to: string; mode: string; numbers_json: string; quote_json: string; quote_at: number; deadline: number;
  status: string | null; status_json: string | null; status_at: number | null; deposit_notified: number;
};

/** One row per cross-chain payment, next to its phone intent. The whole signed 1Click quote is kept for disputes. */
export function openXchainStore(db: Db, now: () => number) {
  db.raw.exec(`CREATE TABLE IF NOT EXISTS pay_xchain (
  intent_id TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE, origin_asset TEXT NOT NULL, dest_asset TEXT NOT NULL,
  dest_chain TEXT NOT NULL, dest_recipient TEXT NOT NULL, deposit_address TEXT NOT NULL, refund_to TEXT NOT NULL, mode TEXT NOT NULL,
  numbers_json TEXT NOT NULL, quote_json TEXT NOT NULL, quote_at INTEGER NOT NULL, deadline INTEGER NOT NULL,
  status TEXT, status_json TEXT, status_at INTEGER, deposit_notified INTEGER NOT NULL DEFAULT 0);`);
  const q = (sql: string) => db.raw.prepare(sql);
  return {
    add(r: Omit<XchainRow, 'status' | 'status_json' | 'status_at' | 'deposit_notified'>) {
      q(`INSERT INTO pay_xchain (intent_id, user_id, origin_asset, dest_asset, dest_chain, dest_recipient, deposit_address, refund_to, mode, numbers_json, quote_json, quote_at, deadline)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`).run(r.intent_id, r.user_id, r.origin_asset, r.dest_asset, r.dest_chain, r.dest_recipient, r.deposit_address, r.refund_to, r.mode, r.numbers_json, r.quote_json, r.quote_at, r.deadline);
    },
    get(intentId: string): XchainRow | undefined {
      return q('SELECT * FROM pay_xchain WHERE intent_id = ?').get(intentId) as XchainRow | undefined;
    },
    setStatus(intentId: string, status: string, json: string) {
      q('UPDATE pay_xchain SET status = ?, status_json = ?, status_at = ? WHERE intent_id = ?').run(status, json, now(), intentId);
    },
    /** Moves a still-pending intent onto a new quote: new max input, deposit account, expiry and numbers. False when it is no longer pending. */
    requote(intentId: string, n: { amount: string; units: string; depositAddress: string; expiresAt: number; numbersJson: string; quoteJson: string; quoteAt: number; deadline: number }): boolean {
      const moved = q("UPDATE pay_phone_intents SET amount = ?, units = ?, recipient = ?, expires_at = ? WHERE id = ? AND status = 'pending'")
        .run(n.amount, n.units, n.depositAddress, n.expiresAt, intentId).changes > 0;
      if (moved) q('UPDATE pay_xchain SET deposit_address = ?, numbers_json = ?, quote_json = ?, quote_at = ?, deadline = ? WHERE intent_id = ?')
        .run(n.depositAddress, n.numbersJson, n.quoteJson, n.quoteAt, n.deadline, intentId);
      return moved;
    },
    /** True when another payment of this user already went to this address on this chain. */
    paidBefore(r: Pick<XchainRow, 'intent_id' | 'user_id' | 'dest_chain' | 'dest_recipient'>): boolean {
      return q(`SELECT 1 FROM pay_xchain x JOIN pay_phone_intents i ON i.id = x.intent_id
        WHERE x.user_id = ? AND x.dest_chain = ? AND x.dest_recipient = ? AND x.intent_id != ? AND i.status = 'sent'`)
        .get(r.user_id, r.dest_chain, r.dest_recipient, r.intent_id) !== undefined;
    },
    /** True for the one caller that claims the deposit notice. */
    claimNotice(intentId: string): boolean {
      return q('UPDATE pay_xchain SET deposit_notified = 1 WHERE intent_id = ? AND deposit_notified = 0').run(intentId).changes > 0;
    },
  };
}
export type XchainStore = ReturnType<typeof openXchainStore>;
