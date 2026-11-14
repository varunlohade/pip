import { Account, JsonRpcProvider, SignedTransaction, type KeyPairString } from 'near-api-js';
import type { NetworkSettings } from '../network.ts';

/** What the phone-signed flow needs from one NEAR network. It never signs a user payment; tests pass a fake. */
export type PhoneChain = {
  accountExists(accountId: string): Promise<boolean>;
  /** The access key's current nonce, or null when the account or key does not exist yet (an unfunded implicit account). */
  accessKeyNonce(accountId: string, publicKey: string): Promise<bigint | null>;
  /** A recent final block hash, base58. */
  recentBlockHash(): Promise<string>;
  storageRegistered(accountId: string): Promise<boolean>;
  storageMin(): Promise<bigint>;
  balances(accountId: string): Promise<{ NEAR: bigint; USDC: bigint }>;
  /** Sends a transaction the phone signed. Throws when the outcome is unknown. */
  broadcast(signed: Uint8Array): Promise<'ok' | 'failed'>;
  /** Testnet only: the server's funder sends free test NEAR to a new account. Returns the tx hash. */
  fund?(accountId: string, units: bigint): Promise<string>;
};

const missing = (e: unknown) => /does not exist|UNKNOWN_ACCOUNT|UNKNOWN_ACCESS_KEY|AccountDoesNotExist|AccessKeyDoesNotExist/i
  .test(String((e as Error).message) + String((e as { type?: string }).type));

export function createPhoneChain(s: NetworkSettings, funder?: { accountId: string; secretKey: string }): PhoneChain {
  const provider = new JsonRpcProvider({ url: s.rpcUrl });
  // The RPC must report the network we expect before anything is broadcast or funded.
  let checked: Promise<void> | undefined;
  const ensureChain = () => (checked ??= provider.viewNodeStatus().then((st) => {
    if (st.chain_id !== s.network) throw new Error(`RPC chain is ${st.chain_id}, not ${s.network}`);
  }).catch((e) => { checked = undefined; throw e; }));
  const view = async <T>(method: string, args: Record<string, unknown>) =>
    (await provider.callFunction({ contractId: s.usdcContract, method, args, blockQuery: { finality: 'final' } })) as T;
  const failed = (status: unknown) => typeof status === 'object' && status !== null && 'Failure' in status;

  const chain: PhoneChain = {
    async accountExists(accountId) {
      try {
        await provider.viewAccount({ accountId });
        return true;
      } catch (e) {
        if (missing(e)) return false;
        throw e;
      }
    },
    async accessKeyNonce(accountId, publicKey) {
      try {
        return (await provider.viewAccessKey({ accountId, publicKey, finalityQuery: { finality: 'final' } })).nonce;
      } catch (e) {
        if (missing(e)) return null;
        throw e;
      }
    },
    async recentBlockHash() {
      await ensureChain();
      return (await provider.viewBlock({ finality: 'final' })).header.hash;
    },
    async storageRegistered(accountId) {
      const r = await view<unknown>('storage_balance_of', { account_id: accountId });
      return r !== null && r !== undefined;
    },
    async storageMin() {
      return BigInt((await view<{ min: string }>('storage_balance_bounds', {})).min);
    },
    async balances(accountId) {
      if (!(await chain.accountExists(accountId))) return { NEAR: 0n, USDC: 0n };
      const acc = await provider.viewAccount({ accountId });
      const usdc = await view<string>('ft_balance_of', { account_id: accountId });
      return { NEAR: acc.amount, USDC: BigInt(usdc ?? '0') };
    },
    async broadcast(signed) {
      await ensureChain();
      const r = await provider.sendTransactionUntil(SignedTransaction.decode(signed), 'FINAL');
      return failed(r.status) ? 'failed' : 'ok';
    },
  };
  if (s.network === 'testnet' && funder?.accountId && funder.secretKey) {
    chain.fund = async (accountId, units) => {
      if (!funder.accountId.endsWith('.testnet')) throw new Error('the funder must be a .testnet account');
      await ensureChain();
      const r = await new Account(funder.accountId, provider, funder.secretKey as KeyPairString).transfer({ receiverId: accountId, amount: units });
      if (failed(r.status)) throw new Error('funding failed');
      return r.transaction.hash;
    };
  }
  return chain;
}
