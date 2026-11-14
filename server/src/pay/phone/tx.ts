import { createHash, createPublicKey, verify } from 'node:crypto';
import { KeyType, PublicKey, Signature, SignedTransaction, Transaction, actions, baseDecode, baseEncode, createTransaction, type Action } from 'near-api-js';
import type { Token } from '../config.ts';

export const GAS = 30_000_000_000_000n;
// DER prefix of an Ed25519 SubjectPublicKeyInfo; the 32 raw key bytes follow.
const SPKI_ED25519 = Buffer.from('302a300506032b6570032100', 'hex');

/** A phone public key: 64 hex chars, or "ed25519:<base58>". Returns the 32 raw bytes, or null. */
export function parsePublicKey(raw: string): Uint8Array | null {
  let bytes: Uint8Array;
  if (/^[0-9a-f]{64}$/.test(raw)) bytes = Buffer.from(raw, 'hex');
  else if (/^ed25519:[1-9A-HJ-NP-Za-km-z]{32,44}$/.test(raw)) bytes = baseDecode(raw.slice(8));
  else return null;
  if (bytes.length !== 32) return null;
  try {
    createPublicKey({ key: Buffer.concat([SPKI_ED25519, bytes]), format: 'der', type: 'spki' });
  } catch {
    return null;
  }
  return bytes;
}

/** A 64-byte Ed25519 signature: base64 or 128 hex chars. */
export function parseSignature(raw: string): Uint8Array | null {
  const bytes = /^[0-9a-f]{128}$/.test(raw) ? Buffer.from(raw, 'hex') : /^[A-Za-z0-9+/]{86}==$/.test(raw) ? Buffer.from(raw, 'base64') : null;
  return bytes?.length === 64 ? bytes : null;
}

/** The implicit account id of an Ed25519 key is its 32 bytes in lower-case hex. */
export const implicitAccountId = (pk: Uint8Array) => Buffer.from(pk).toString('hex');
export const nearPublicKey = (pk: Uint8Array) => `ed25519:${baseEncode(pk)}`;
export const sha256 = (b: Uint8Array) => new Uint8Array(createHash('sha256').update(b).digest());

export type TransferPlan = {
  signerId: string; publicKey: Uint8Array; nonce: bigint; blockHash: string;
  token: Token; recipient: string; units: bigint; usdcContract: string;
  /** USDC only: the deposit for storage_deposit when the recipient is not registered on the token; null when it is. */
  storageDeposit: bigint | null;
};

/** The exact transaction the phone will sign. Pure: the same plan always gives the same bytes. */
export function buildTransfer(p: TransferPlan): { bytes: Uint8Array; hash: Uint8Array; receiverId: string } {
  const acts: Action[] = [];
  let receiverId = p.recipient;
  if (p.token === 'NEAR') acts.push(actions.transfer(p.units));
  else {
    receiverId = p.usdcContract;
    if (p.storageDeposit !== null) acts.push(actions.functionCall('storage_deposit', { account_id: p.recipient, registration_only: true }, GAS, p.storageDeposit));
    acts.push(actions.functionCall('ft_transfer', { receiver_id: p.recipient, amount: p.units.toString() }, GAS, 1n));
  }
  const tx = createTransaction(p.signerId, new PublicKey({ keyType: KeyType.ED25519, data: p.publicKey }), receiverId, p.nonce, acts, baseDecode(p.blockHash));
  const bytes = tx.encode();
  return { bytes, hash: sha256(bytes), receiverId };
}

/** NEAR checks an Ed25519 signature over sha256(transaction bytes). So does this. */
export function verifySignature(publicKey: Uint8Array, hash: Uint8Array, signature: Uint8Array): boolean {
  if (signature.length !== 64 || hash.length !== 32) return false;
  const key = createPublicKey({ key: Buffer.concat([SPKI_ED25519, publicKey]), format: 'der', type: 'spki' });
  return verify(null, hash, key, signature);
}

/**
 * What the keyboard signs to approve an intent for a recipient never paid before: the phone key over sha256 of this text.
 * Plain UTF-8 with a fixed prefix, so it can never be read as a NEAR transaction (those start with a u32 length).
 */
export const approvalMessage = (i: { id: string; network: string; amount: string; token: string; recipient: string }) =>
  new TextEncoder().encode(['pip-approve/v1', i.id, i.network, i.amount, i.token, i.recipient].join('\n'));

/** The signed transaction, ready to broadcast. */
export function signedBytes(txBytes: Uint8Array, signature: Uint8Array): Uint8Array {
  return new SignedTransaction({ transaction: Transaction.decode(txBytes), signature: new Signature({ keyType: KeyType.ED25519, data: signature }) }).encode();
}
