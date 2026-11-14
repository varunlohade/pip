import { KeyType, PublicKey, actions, baseDecode, createTransaction, type Action } from 'near-api-js';
import { GAS, sha256 } from '../phone/tx.ts';

export type DepositPlan = {
  signerId: string; publicKey: Uint8Array; nonce: bigint; blockHash: string;
  /** The NEP-141 contract of the origin asset (wrap.near for NEAR). */
  contract: string; depositAddress: string; units: bigint;
  /** NEAR origin: wrap `units` yoctoNEAR into wNEAR first, in the same transaction. */
  wrap: boolean;
  /** storage_deposit for the signer on wrap.near (wrap only), and for the deposit account; null when registered. */
  signerStorage: bigint | null; depositStorage: bigint | null;
};

/**
 * The one transaction that funds a 1Click quote: every action goes to the origin token contract.
 * [storage_deposit(signer)] [storage_deposit(deposit)] [near_deposit(units)] ft_transfer(deposit, units). Pure.
 */
export function buildDeposit(p: DepositPlan): { bytes: Uint8Array; hash: Uint8Array; receiverId: string } {
  const acts: Action[] = [];
  if (p.wrap && p.signerStorage !== null) acts.push(actions.functionCall('storage_deposit', { account_id: p.signerId, registration_only: true }, GAS, p.signerStorage));
  if (p.depositStorage !== null) acts.push(actions.functionCall('storage_deposit', { account_id: p.depositAddress, registration_only: true }, GAS, p.depositStorage));
  if (p.wrap) acts.push(actions.functionCall('near_deposit', {}, GAS, p.units));
  acts.push(actions.functionCall('ft_transfer', { receiver_id: p.depositAddress, amount: p.units.toString() }, GAS, 1n));
  const tx = createTransaction(p.signerId, new PublicKey({ keyType: KeyType.ED25519, data: p.publicKey }), p.contract, p.nonce, acts, baseDecode(p.blockHash));
  const bytes = tx.encode();
  return { bytes, hash: sha256(bytes), receiverId: p.contract };
}
