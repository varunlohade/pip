import type { Db } from '../../db.ts';

export type XchainRow = {
  intent_id: string; user_id: string; origin_asset: string; dest_asset: string; dest_chain: string; dest_recipient: string;
  deposit_address: string; refund_to: string; mode: string; numbers_json: string; quote_json: string; quote_at: number; deadline: number;
  status: string | null; status_json: string | null; status_at: number | null; deposit_notified: number;
  /** 'pay' to someone, or 'swap' to the user's own account or saved address. */
  kind: string;
};

/** One row per cross-chain payment, next to its phone intent. The whole signed 1Click quote is kept for disputes. */
export function openXchainStore(db: Db, now: () => number) {
  db.raw.exec(`CREATE TABLE IF NOT EXISTS pay_xchain (
  intent_id TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE, origin_asset TEXT NOT NULL, dest_asset TEXT NOT NULL,
  dest_chain TEXT NOT NULL, dest_recipient TEXT NOT NULL, deposit_address TEXT NOT NULL, refund_to TEXT NOT NULL, mode TEXT NOT NULL,
  numbers_json TEXT NOT NULL, quote_json TEXT NOT NULL, quote_at INTEGER NOT NULL, deadline INTEGER NOT NULL,
  status TEXT, status_json TEXT, status_at INTEGER, deposit_notified INTEGER NOT NULL DEFAULT 0);`);
  const cols = new Set((db.raw.prepare('PRAGMA table_info(pay_xchain)').all() as { name: string }[]).map((c) => c.name));
  if (!cols.has('kind')) db.raw.exec("ALTER TABLE pay_xchain ADD COLUMN kind TEXT NOT NULL DEFAULT 'pay'");
  const q = (sql: string) => db.raw.prepare(sql);
  return {
    add(r: Omit<XchainRow, 'status' | 'status_json' | 'status_at' | 'deposit_notified' | 'kind'> & { kind?: 'pay' | 'swap' }) {
      q(`INSERT INTO pay_xchain (intent_id, user_id, origin_asset, dest_asset, dest_chain, dest_recipient, deposit_address, refund_to, mode, numbers_json, quote_json, quote_at, deadline, kind)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`).run(r.intent_id, r.user_id, r.origin_asset, r.dest_asset, r.dest_chain, r.dest_recipient, r.deposit_address, r.refund_to, r.mode, r.numbers_json, r.quote_json, r.quote_at, r.deadline, r.kind ?? 'pay');
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

/** The user's own addresses on other chains ("My addresses"). Swaps to another chain deliver only here. */
export function openOwnAddressStore(db: Db, now: () => number) {
  db.raw.exec(`CREATE TABLE IF NOT EXISTS pay_own_addresses (
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE, chain TEXT NOT NULL, address TEXT NOT NULL, added_at INTEGER NOT NULL,
  PRIMARY KEY (user_id, chain));`);
  const q = (sql: string) => db.raw.prepare(sql);
  return {
    list(userId: string): { chain: string; address: string }[] {
      return q('SELECT chain, address FROM pay_own_addresses WHERE user_id = ? ORDER BY chain').all(userId) as { chain: string; address: string }[];
    },
    get(userId: string, chain: string): string | undefined {
      return (q('SELECT address FROM pay_own_addresses WHERE user_id = ? AND chain = ?').get(userId, chain) as { address: string } | undefined)?.address;
    },
    set(userId: string, chain: string, address: string) {
      q('INSERT INTO pay_own_addresses (user_id, chain, address, added_at) VALUES (?, ?, ?, ?) ON CONFLICT (user_id, chain) DO UPDATE SET address = excluded.address, added_at = excluded.added_at')
        .run(userId, chain, address, now());
    },
    remove(userId: string, chain: string): boolean {
      return q('DELETE FROM pay_own_addresses WHERE user_id = ? AND chain = ?').run(userId, chain).changes > 0;
    },
  };
}

export type RequestRow = {
  id: string; user_id: string; kind: string; origin_asset: string; origin_chain: string; dest_asset: string; recipient: string; deposit_address: string;
  refund_to: string; numbers_json: string; quote_json: string; quote_at: number; deadline: number; status: string | null; status_json: string | null; status_at: number | null;
};

/** Receive requests and top-ups: a 1Click deposit address on the payer's chain that delivers to the user's NEAR account. Pip moves no money here. */
export function openRequestStore(db: Db, now: () => number) {
  db.raw.exec(`CREATE TABLE IF NOT EXISTS pay_xchain_requests (
  id TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE, kind TEXT NOT NULL, origin_asset TEXT NOT NULL, origin_chain TEXT NOT NULL,
  dest_asset TEXT NOT NULL, recipient TEXT NOT NULL, deposit_address TEXT NOT NULL, refund_to TEXT NOT NULL, numbers_json TEXT NOT NULL, quote_json TEXT NOT NULL,
  quote_at INTEGER NOT NULL, deadline INTEGER NOT NULL, status TEXT, status_json TEXT, status_at INTEGER);`);
  const q = (sql: string) => db.raw.prepare(sql);
  return {
    add(r: Omit<RequestRow, 'status' | 'status_json' | 'status_at'>) {
      q(`INSERT INTO pay_xchain_requests (id, user_id, kind, origin_asset, origin_chain, dest_asset, recipient, deposit_address, refund_to, numbers_json, quote_json, quote_at, deadline)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`).run(r.id, r.user_id, r.kind, r.origin_asset, r.origin_chain, r.dest_asset, r.recipient, r.deposit_address, r.refund_to, r.numbers_json, r.quote_json, r.quote_at, r.deadline);
    },
    get(id: string): RequestRow | undefined {
      return q('SELECT * FROM pay_xchain_requests WHERE id = ?').get(id) as RequestRow | undefined;
    },
    setStatus(id: string, status: string, json: string) {
      q('UPDATE pay_xchain_requests SET status = ?, status_json = ?, status_at = ? WHERE id = ?').run(status, json, now(), id);
    },
  };
}
