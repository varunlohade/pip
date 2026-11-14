import type { Db } from '../db.ts';
import { payConfig, type PayConfig, type Token } from './config.ts';
import { checkRecipient } from './parse.ts';

const env = process.env;

export type Network = 'testnet' | 'mainnet';
export type Caps = Record<Token, { perTx: string; daily: string }>;

/** Mainnet settings. Off unless PAY_MAINNET=1. The server holds no mainnet key: it only builds and broadcasts. */
export const mainnetConfig = {
  enabled: env.PAY_MAINNET === '1',
  rpcUrl: env.NEAR_MAINNET_RPC_URL ?? 'https://free.rpc.fastnear.com',
  explorerTx: 'https://nearblocks.io/txns/',
  // Circle's native USDC on NEAR mainnet, 6 decimals.
  usdcContract: '17208628f84f5d6ad33f0da3bbbeb27ffcb398eac501a31bd6ad2011e36133a1',
  caps: {
    NEAR: { perTx: env.PAY_MAINNET_MAX_PER_TX_NEAR ?? '2', daily: env.PAY_MAINNET_MAX_DAILY_NEAR ?? '5' },
    USDC: { perTx: env.PAY_MAINNET_MAX_PER_TX_USDC ?? '10', daily: env.PAY_MAINNET_MAX_DAILY_USDC ?? '20' },
    USDT: { perTx: env.PAY_MAINNET_MAX_PER_TX_USDT ?? '10', daily: env.PAY_MAINNET_MAX_DAILY_USDT ?? '20' },
  } as Caps,
};
export type MainnetConfig = typeof mainnetConfig;

/** What one network needs for the phone-signed flow. */
export type NetworkSettings = { network: Network; rpcUrl: string; explorerTx: string; usdcContract: string; caps: Caps };

export function settingsFor(network: Network, pay: PayConfig = payConfig, main: MainnetConfig = mainnetConfig): NetworkSettings {
  if (network === 'mainnet') return { network, rpcUrl: main.rpcUrl, explorerTx: main.explorerTx, usdcContract: main.usdcContract, caps: main.caps };
  return { network, rpcUrl: pay.rpcUrl, explorerTx: pay.explorerTx, usdcContract: pay.usdcContract, caps: pay.caps };
}

/** Recipient rules per network. Testnet keeps the parser's rules; mainnet takes .near names and implicit (64 hex) ids only. */
export function recipientRule(network: Network): typeof checkRecipient {
  if (network === 'testnet') return checkRecipient;
  return (raw) => {
    const r = checkRecipient(raw);
    if (r.ok) return r.id.endsWith('.testnet') ? { ok: false, reason: 'testnet accounts are not allowed on mainnet' } : r;
    const id = raw.replace(/^@/, '').replace(/\.$/, '');
    if (/^(([a-z\d]+[-_])*[a-z\d]+\.)+near$/.test(id) && id.length <= 64) return { ok: true, id };
    if (r.reason.startsWith('write the full account id')) return { ok: false, reason: `write the full account id, like ${id}.near` };
    if (r.reason.startsWith('only .testnet')) return { ok: false, reason: 'only .near accounts are allowed on mainnet' };
    return r;
  };
}

/** Each user's network choice. Testnet until the app switches it. */
export function openNetworkStore(db: Db, now: () => number) {
  db.raw.exec(`CREATE TABLE IF NOT EXISTS pay_network (
  user_id TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE, network TEXT NOT NULL, updated_at INTEGER NOT NULL);`);
  return {
    get(userId: string): Network {
      const row = db.raw.prepare('SELECT network FROM pay_network WHERE user_id = ?').get(userId) as { network: Network } | undefined;
      return row?.network ?? 'testnet';
    },
    set(userId: string, network: Network) {
      db.raw.prepare('INSERT INTO pay_network (user_id, network, updated_at) VALUES (?, ?, ?) ON CONFLICT(user_id) DO UPDATE SET network = excluded.network, updated_at = excluded.updated_at')
        .run(userId, network, now());
    },
  };
}
