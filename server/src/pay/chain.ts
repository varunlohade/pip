import { createHash } from 'node:crypto';
import { Account, JsonRpcProvider, KeyPair, PublicKey, actions, baseEncode, type Action, type KeyPairString } from 'near-api-js';
import { assertTestnet, type PayConfig, type Token } from './config.ts';

export type Signer = { accountId: string; secretKey: string };
/** A send, signed and ready. The hash is known before broadcast, so an unknown outcome can still be looked up. */
export type Prepared = { hash: string; broadcast(): Promise<'ok' | 'failed'> };

/** Everything payments need from NEAR. Tests pass a fake; the real one talks to a testnet RPC. */
export type Chain = {
  accountExists(accountId: string): Promise<boolean>;
  /** Balances in base units; usdc is 0 when the account is not registered on the token. */
  balances(accountId: string): Promise<{ NEAR: bigint; USDC: bigint }>;
  newKey(): { publicKey: string; secretKey: string };
  /** The funder creates `accountId` (its sub-account) with this key and gives it `near` base units. Returns the tx hash. */
  createAccount(accountId: string, publicKey: string, near: bigint): Promise<string>;
  prepareSend(from: Signer, token: Token, recipient: string, units: bigint): Promise<Prepared>;
};

const GAS = 30_000_000_000_000n;

export function createNearChain(cfg: PayConfig): Chain {
  assertTestnet(cfg);
  const provider = new JsonRpcProvider({ url: cfg.rpcUrl });
  // The RPC itself must say it is testnet before any key signs anything.
  let checked: Promise<void> | undefined;
  const ensureTestnet = () => (checked ??= provider.viewNodeStatus().then((s) => {
    if (s.chain_id !== 'testnet') throw new Error(`RPC chain is ${s.chain_id}, not testnet`);
  }).catch((e) => { checked = undefined; throw e; }));
  const view = async <T>(contractId: string, method: string, args: Record<string, unknown>) =>
    (await provider.callFunction({ contractId, method, args, blockQuery: { finality: 'final' } })) as T;

  const accountExists = async (accountId: string) => {
    try {
      await provider.viewAccount({ accountId });
      return true;
    } catch (e) {
      if (/does not exist|UNKNOWN_ACCOUNT|AccountDoesNotExist/i.test(String((e as Error).message) + String((e as { type?: string }).type))) return false;
      throw e;
    }
  };

  const signed = async (signer: Signer, receiverId: string, acts: Action[]): Promise<Prepared> => {
    await ensureTestnet();
    const account = new Account(signer.accountId, provider, signer.secretKey as KeyPairString);
    const tx = await account.createSignedTransaction({ receiverId, actions: acts });
    const hash = baseEncode(createHash('sha256').update(tx.transaction.encode()).digest());
    return {
      hash,
      async broadcast() {
        const r = await provider.sendTransactionUntil(tx, 'FINAL');
        const status = r.status as { Failure?: unknown } | string;
        return typeof status === 'object' && status && 'Failure' in status ? 'failed' : 'ok';
      },
    };
  };

  return {
    accountExists,
    async balances(accountId) {
      const acc = await provider.viewAccount({ accountId });
      const usdc = await view<string>(cfg.usdcContract, 'ft_balance_of', { account_id: accountId });
      return { NEAR: acc.amount, USDC: BigInt(usdc ?? '0') };
    },
    newKey() {
      const kp = KeyPair.fromRandom('ed25519');
      return { publicKey: kp.getPublicKey().toString(), secretKey: kp.toString() };
    },
    async createAccount(accountId, publicKey, near) {
      const p = await signed({ accountId: cfg.funderAccountId, secretKey: cfg.funderSecretKey }, accountId, [
        actions.createAccount(), actions.transfer(near), actions.addFullAccessKey(PublicKey.fromString(publicKey)),
      ]);
      if ((await p.broadcast()) !== 'ok') throw new Error('create account failed');
      return p.hash;
    },
    async prepareSend(from, token, recipient, units) {
      if (token === 'NEAR') return signed(from, recipient, [actions.transfer(units)]);
      // USDC: register the receiver on the token first when needed (paid by the sender), then ft_transfer with 1 yoctoNEAR.
      const reg = await view<unknown>(cfg.usdcContract, 'storage_balance_of', { account_id: recipient });
      const acts: Action[] = [];
      if (reg === null || reg === undefined) {
        const bounds = await view<{ min: string }>(cfg.usdcContract, 'storage_balance_bounds', {});
        acts.push(actions.functionCall('storage_deposit', { account_id: recipient, registration_only: true }, GAS, BigInt(bounds.min)));
      }
      acts.push(actions.functionCall('ft_transfer', { receiver_id: recipient, amount: units.toString() }, GAS, 1n));
      return signed(from, cfg.usdcContract, acts);
    },
  };
}
