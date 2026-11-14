// Phone-signed NEAR payments, played from a terminal instead of a phone.
//   node scripts/mainnet-sign-demo.ts key                 make (or load) a local Ed25519 key; print the implicit account to fund
//   node scripts/mainnet-sign-demo.ts example             print an unsigned tx for this key with a fake nonce and block (offline)
//   PIP_CONFIRM_MAINNET=yes node scripts/mainnet-sign-demo.ts send <server> <access token> <approver key> <amount> <NEAR|USDC> <recipient.near>
//                                                         the full flow on MAINNET through a Pip server. Real money: needs the owner's OK.
// The key lives in PIP_DEMO_KEY_FILE (default ~/.pip-mainnet-demo-key.json, mode 0600). It is never printed.
import { createPrivateKey, generateKeyPairSync, sign } from 'node:crypto';
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { Transaction } from 'near-api-js';
import { mainnetConfig } from '../src/pay/network.ts';
import { buildTransfer, implicitAccountId, nearPublicKey, verifySignature } from '../src/pay/phone/tx.ts';

const file = process.env.PIP_DEMO_KEY_FILE ?? join(homedir(), '.pip-mainnet-demo-key.json');

function loadKey() {
  if (!existsSync(file)) {
    const { privateKey } = generateKeyPairSync('ed25519');
    writeFileSync(file, JSON.stringify({ jwk: privateKey.export({ format: 'jwk' }) }), { mode: 0o600 });
  }
  const privateKey = createPrivateKey({ key: JSON.parse(readFileSync(file, 'utf8')).jwk, format: 'jwk' });
  const raw = new Uint8Array(Buffer.from(privateKey.export({ format: 'jwk' }).x!, 'base64url'));
  return { privateKey, raw, hex: implicitAccountId(raw) };
}
const signHash = (hashHex: string, key: ReturnType<typeof loadKey>) => sign(null, Buffer.from(hashHex, 'hex'), key.privateKey).toString('base64');

const [cmd, ...args] = process.argv.slice(2);
const key = loadKey();

if (cmd === 'key') {
  console.log(`implicit account (fund this on mainnet): ${key.hex}`);
  console.log(`public key: ${nearPublicKey(key.raw)}`);
  console.log(`explorer: https://nearblocks.io/address/${key.hex}`);
} else if (cmd === 'example') {
  const plan = { signerId: key.hex, publicKey: key.raw, nonce: 123456789000001n, blockHash: 'GJ8ThW5tGmvBbGr8Kto6Ahtv1mhK5cXhkRMdNsJxbVkK', token: 'USDC' as const,
    recipient: 'ana.near', units: 1_500_000n, usdcContract: mainnetConfig.usdcContract, storageDeposit: 1_250_000_000_000_000_000_000n };
  const tx = buildTransfer(plan);
  const hashHex = Buffer.from(tx.hash).toString('hex');
  const sig = Buffer.from(signHash(hashHex, key), 'base64');
  const decoded = Transaction.decode(tx.bytes);
  console.log(JSON.stringify({
    signer_id: decoded.signerId, receiver_id: decoded.receiverId, nonce: decoded.nonce.toString(),
    actions: decoded.actions.map((a) => a.functionCall ? { method: a.functionCall.methodName, args: Buffer.from(a.functionCall.args).toString(), deposit: a.functionCall.deposit.toString() } : a),
    tx_base64: Buffer.from(tx.bytes).toString('base64'), sign_hash_hex: hashHex, signature_base64: sig.toString('base64'),
    signature_ok: verifySignature(key.raw, tx.hash, sig), broadcast: 'not sent (offline example)',
  }, null, 2));
} else if (cmd === 'send') {
  if (process.env.PIP_CONFIRM_MAINNET !== 'yes') throw new Error('this moves real money; set PIP_CONFIRM_MAINNET=yes only with the owner\'s OK');
  const [server, token, approver, amount, tok, recipient] = args;
  const call = async (method: string, path: string, body?: unknown) => {
    const r = await fetch(`${server}${path}`, { method, headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}`, 'X-Pay-Approver': approver }, body: body === undefined ? undefined : JSON.stringify(body) });
    const j = await r.json();
    console.log(method, path, r.status, JSON.stringify(j));
    if (!r.ok && r.status !== 202) throw new Error(`${path} answered ${r.status}`);
    return j;
  };
  await call('PUT', '/v1/pay/network', { network: 'mainnet' });
  await call('POST', '/v1/pay/register', { publicKey: key.hex });
  const fields = { amount, token: tok, recipient };
  const intent = await call('POST', '/v1/pay/intents', fields);
  const unsigned = await call('POST', `/v1/pay/intents/${intent.id}/unsigned`, fields);
  const done = await call('POST', `/v1/pay/intents/${intent.id}/submit`, { signature: signHash(unsigned.sign_hash_hex, key) });
  console.log(`status: ${done.status} ${done.explorer_url ?? ''}`);
} else {
  console.log('usage: key | example | send <server> <token> <approver> <amount> <NEAR|USDC> <recipient>');
}
