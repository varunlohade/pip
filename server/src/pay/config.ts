const env = process.env;

export type Token = 'NEAR' | 'USDC';

/** Payments run on NEAR testnet only. Nothing here can point at mainnet: see assertTestnet. */
export const payConfig = {
  network: 'testnet' as const,
  rpcUrl: env.NEAR_RPC_URL ?? 'https://test.rpc.fastnear.com',
  explorerTx: 'https://testnet.nearblocks.io/txns/',
  // The server's testnet account. It creates and funds one sub-account per user. Unset: payments answer 503.
  funderAccountId: env.PAY_FUNDER_ACCOUNT_ID ?? '',
  funderSecretKey: env.PAY_FUNDER_PRIVATE_KEY ?? '',
  // Circle's testnet USDC on NEAR, 6 decimals.
  usdcContract: env.PAY_USDC_CONTRACT ?? '3e2210e1184b45b64c8a434c0a7e7b23cc04ea7eb7a6c3c32520d03d4afcb8af',
  decimals: { NEAR: 24, USDC: 6 } as Record<Token, number>,
  // Caps in whole tokens, per payment and per rolling 24 hours, per user.
  caps: {
    NEAR: { perTx: env.PAY_MAX_PER_TX_NEAR ?? '1', daily: env.PAY_MAX_DAILY_NEAR ?? '2' },
    USDC: { perTx: env.PAY_MAX_PER_TX_USDC ?? '10', daily: env.PAY_MAX_DAILY_USDC ?? '25' },
  } as Record<Token, { perTx: string; daily: string }>,
  // Each new wallet gets this much testnet NEAR from the funder, for gas and small sends.
  newWalletNear: env.PAY_NEW_WALLET_NEAR ?? '0.2',
  // A cap on wallets made in total, so free device accounts cannot drain the funder.
  maxWallets: Number(env.PAY_MAX_WALLETS ?? 100),
  intentTtlMs: 10 * 60_000,
  // Legacy: the server holds each user's testnet key and signs (wallet + approve). Off unless PAY_LEGACY_CUSTODY=1; the phone signs instead (src/pay/phone).
  legacyCustody: env.PAY_LEGACY_CUSTODY === '1',
};

export type PayConfig = typeof payConfig;

/** Throws unless every account and the RPC are testnet. Runs before any key is used. */
export function assertTestnet(c: Pick<PayConfig, 'rpcUrl' | 'funderAccountId' | 'network'>) {
  if (c.network !== 'testnet') throw new Error('payments run on testnet only');
  if (/mainnet/i.test(c.rpcUrl)) throw new Error('NEAR_RPC_URL must be a testnet RPC');
  if (c.funderAccountId && !c.funderAccountId.endsWith('.testnet')) throw new Error('PAY_FUNDER_ACCOUNT_ID must end with .testnet');
}
