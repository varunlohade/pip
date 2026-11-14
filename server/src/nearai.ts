import { AsyncLocalStorage } from 'node:async_hooks';
import { createHash, randomBytes, X509Certificate, createPublicKey, verify as cryptoVerify } from 'node:crypto';
import { config } from './config.ts';
import { log } from './log.ts';

// NEAR AI Cloud private inference: the model runs in a TEE (Intel TDX + NVIDIA GPU) that NEAR runs.
// Before a model counts as "attested", this file checks NEAR's attestation report the way the docs describe
// (docs.near.ai/cloud/verification): the Intel TDX quote, the nonce and signer bound inside it, the measured config and RTMR3.
// After each reply it fetches the response signature and checks that the attested model key signed these exact bytes.

// ---- which models served a request (read by app.ts to set private / attested / model)

export type Served = { model: string; private: boolean; attested: boolean };
export type Privacy = { private: boolean; attested: boolean; model: string | null };
const served = new AsyncLocalStorage<Served[]>();

export function noteServed(s: Served) {
  served.getStore()?.push(s);
}

/** Runs `run` and reports which models answered: private only if every model call ran in a TEE, attested only if every one was checked. */
export async function tracked<T>(run: () => Promise<T>): Promise<{ out: T; privacy: Privacy }> {
  const calls: Served[] = [];
  const out = await served.run(calls, run);
  return {
    out,
    privacy: calls.length
      ? { private: calls.every((c) => c.private), attested: calls.every((c) => c.attested), model: calls.at(-1)!.model }
      : { private: false, attested: false, model: null },
  };
}

// ---- keccak-256 (Ethereum addresses and EIP-191). Node's OpenSSL build has SHA3 but not the original Keccak padding.

const MASK = (1n << 64n) - 1n;
const RC = [
  0x1n, 0x8082n, 0x800000000000808an, 0x8000000080008000n, 0x808bn, 0x80000001n, 0x8000000080008081n, 0x8000000000008009n,
  0x8an, 0x88n, 0x80008009n, 0x8000000an, 0x8000808bn, 0x800000000000008bn, 0x8000000000008089n, 0x8000000000008003n,
  0x8000000000008002n, 0x8000000000000080n, 0x800an, 0x800000008000000an, 0x8000000080008081n, 0x8000000000008080n, 0x80000001n, 0x8000000080008008n,
];
const ROT = [0, 1, 62, 28, 27, 36, 44, 6, 55, 20, 3, 10, 43, 25, 39, 41, 45, 15, 21, 8, 18, 2, 61, 56, 14];
const rotl = (v: bigint, n: number) => (n === 0 ? v : ((v << BigInt(n)) | (v >> BigInt(64 - n))) & MASK);

function keccakF(a: bigint[]) {
  for (let round = 0; round < 24; round++) {
    const c = [0, 1, 2, 3, 4].map((x) => a[x] ^ a[x + 5] ^ a[x + 10] ^ a[x + 15] ^ a[x + 20]);
    for (let x = 0; x < 5; x++) {
      const d = c[(x + 4) % 5] ^ rotl(c[(x + 1) % 5], 1);
      for (let y = 0; y < 25; y += 5) a[x + y] ^= d;
    }
    const b = new Array<bigint>(25);
    for (let x = 0; x < 5; x++) for (let y = 0; y < 5; y++) b[y + 5 * ((2 * x + 3 * y) % 5)] = rotl(a[x + 5 * y], ROT[x + 5 * y]);
    for (let x = 0; x < 5; x++) for (let y = 0; y < 25; y += 5) a[x + y] = b[x + y] ^ (~b[((x + 1) % 5) + y] & MASK & b[((x + 2) % 5) + y]);
    a[0] ^= RC[round];
  }
}

export function keccak256(data: Uint8Array): Buffer {
  const rate = 136;
  const padded = Buffer.alloc(Math.floor(data.length / rate) * rate + rate);
  padded.set(data);
  padded[data.length] ^= 0x01;
  padded[padded.length - 1] ^= 0x80;
  const a = new Array<bigint>(25).fill(0n);
  for (let off = 0; off < padded.length; off += rate) {
    for (let i = 0; i < rate / 8; i++) a[i] ^= padded.readBigUInt64LE(off + i * 8);
    keccakF(a);
  }
  const out = Buffer.alloc(32);
  for (let i = 0; i < 4; i++) out.writeBigUInt64LE(a[i], i * 8);
  return out;
}

// ---- secp256k1 signer recovery for EIP-191 (Node can verify secp256k1, but not recover a signer from a prehashed message)

const P = 2n ** 256n - 2n ** 32n - 977n;
const N = 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141n;
const G = { x: 0x79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798n, y: 0x483ada7726a3c4655da4fbfc0e1108a8fd17b448a68554199c47d08ffb10d4b8n };
type Point = { x: bigint; y: bigint } | null;
const mod = (a: bigint, m: bigint) => ((a % m) + m) % m;
function inv(a: bigint, m: bigint): bigint {
  let [r0, r1, s0, s1] = [mod(a, m), m, 1n, 0n];
  while (r1) { const q = r0 / r1; [r0, r1] = [r1, r0 - q * r1]; [s0, s1] = [s1, s0 - q * s1]; }
  return mod(s0, m);
}
function pow(b: bigint, e: bigint, m: bigint): bigint {
  let r = 1n;
  for (b = mod(b, m); e; e >>= 1n, b = (b * b) % m) if (e & 1n) r = (r * b) % m;
  return r;
}
function add(p: Point, q: Point): Point {
  if (!p) return q;
  if (!q) return p;
  if (p.x === q.x && mod(p.y + q.y, P) === 0n) return null;
  const l = p.x === q.x ? mod(3n * p.x * p.x * inv(2n * p.y, P), P) : mod((q.y - p.y) * inv(q.x - p.x, P), P);
  const x = mod(l * l - p.x - q.x, P);
  return { x, y: mod(l * (p.x - x) - p.y, P) };
}
function mul(p: Point, k: bigint): Point {
  let r: Point = null;
  for (; k > 0n; k >>= 1n, p = add(p, p)) if (k & 1n) r = add(r, p);
  return r;
}
const big = (b: Uint8Array) => BigInt('0x' + (Buffer.from(b).toString('hex') || '0'));
const be32 = (v: bigint) => Buffer.from(v.toString(16).padStart(64, '0'), 'hex');

/** The Ethereum address of an uncompressed public key (64 bytes x||y, or 65 with the 04 prefix). */
export function addressOf(publicKey: Uint8Array): string {
  const raw = publicKey.length === 65 ? publicKey.subarray(1) : publicKey;
  return '0x' + keccak256(raw).subarray(12).toString('hex');
}

/** Recovers the signer address from a 32-byte digest and a 65-byte r||s||v signature, or null when it is not valid. */
export function recoverAddress(digest: Uint8Array, signature: Uint8Array): string | null {
  if (signature.length !== 65) return null;
  const r = big(signature.subarray(0, 32)), s = big(signature.subarray(32, 64));
  const v = signature[64] >= 27 ? signature[64] - 27 : signature[64];
  if (v > 1 || r <= 0n || r >= N || s <= 0n || s >= N) return null;
  const y2 = mod(r ** 3n + 7n, P);
  let y = pow(y2, (P + 1n) / 4n, P);
  if ((y * y) % P !== y2) return null;
  if (Number(y & 1n) !== v) y = P - y;
  const rInv = inv(r, N);
  const e = big(digest);
  const q = add(mul({ x: r, y }, mod(s * rInv, N)), mul(G, mod(-e * rInv, N)));
  if (!q) return null;
  return addressOf(Buffer.concat([be32(q.x), be32(q.y)]));
}

/** EIP-191 personal_sign signer of `text`. */
export function recoverEip191(text: string, signatureHex: string): string | null {
  const msg = Buffer.from(text, 'utf8');
  const digest = keccak256(Buffer.concat([Buffer.from(`\x19Ethereum Signed Message:\n${msg.length}`), msg]));
  return recoverAddress(digest, Buffer.from(signatureHex.replace(/^0x/, ''), 'hex'));
}

// ---- Intel TDX quote (v4) checks with Node crypto only

// SHA-256 fingerprint of Intel's SGX/TDX root CA, from certificates.trustedservices.intel.com/Intel_SGX_Provisioning_Certification_RootCA.cer
export const INTEL_ROOT_SHA256 = '44:A0:19:6B:2B:99:F8:89:B8:E1:49:E9:5B:80:7A:35:0E:74:24:96:43:99:E8:85:A7:CB:B8:CC:FA:B6:74:D3';

/** What this server does NOT check yet. Shown on the attestation screen so nobody reads more into "attested". */
export const NOT_CHECKED = [
  'Intel TCB status and revocation lists (collateral): a quote from out-of-date firmware still passes',
  'NVIDIA GPU evidence (nvidia_payload via NRAS)',
  'An allowlist of the measured app and OS hashes: we check they match the quote, not that they are a known good build',
  'Pip\'s server sees your text before it reaches the TEE: this is private from NEAR and the model host, not from Pip',
];

type TdQuote = { body: Buffer; tdAttributes: Buffer; mrConfigId: Buffer; rtmr3: Buffer; reportData: Buffer };

/** Parses a TDX v4 quote and checks its signature chain up to Intel's root. Throws with the first failed check. */
export function verifyTdxQuote(quoteHex: string, now: number): TdQuote {
  const q = Buffer.from(quoteHex, 'hex');
  if (q.length < 1020 || q.readUInt16LE(0) !== 4 || q.readUInt32LE(4) !== 0x81) throw new Error('not a TDX v4 quote');
  const signed = q.subarray(0, 632);
  const body = q.subarray(48, 632);
  let o = 636;
  const sig = q.subarray(o, o + 64), attestKey = q.subarray(o + 64, o + 128);
  o += 128;
  if (q.readUInt16LE(o) !== 6) throw new Error('quote has no QE report');
  o += 6;
  const qeReport = q.subarray(o, o + 384), qeSig = q.subarray(o + 384, o + 448);
  o += 448;
  const authLen = q.readUInt16LE(o);
  const authData = q.subarray(o + 2, o + 2 + authLen);
  o += 2 + authLen;
  if (q.readUInt16LE(o) !== 5) throw new Error('quote has no PCK certificate chain');
  const chainLen = q.readUInt32LE(o + 2);
  const pems = q.subarray(o + 6, o + 6 + chainLen).toString('utf8').match(/-----BEGIN CERTIFICATE-----[\s\S]+?-----END CERTIFICATE-----/g) ?? [];
  const certs = pems.map((p) => new X509Certificate(p));
  if (certs.length < 3) throw new Error('PCK chain is short');
  const root = certs.at(-1)!;
  if (root.fingerprint256 !== INTEL_ROOT_SHA256) throw new Error('chain does not end at the Intel root CA');
  for (let i = 0; i < certs.length; i++) {
    const issuer = certs[Math.min(i + 1, certs.length - 1)];
    if (!certs[i].verify(issuer.publicKey)) throw new Error('PCK chain signature is wrong');
    if (now < Date.parse(certs[i].validFrom) || now > Date.parse(certs[i].validTo)) throw new Error('PCK chain certificate is out of date');
  }
  const p256 = (raw: Buffer) => createPublicKey({ key: { kty: 'EC', crv: 'P-256', x: raw.subarray(0, 32).toString('base64url'), y: raw.subarray(32, 64).toString('base64url') }, format: 'jwk' });
  if (!cryptoVerify('sha256', qeReport, { key: certs[0].publicKey, dsaEncoding: 'ieee-p1363' }, qeSig)) throw new Error('QE report signature is wrong');
  const bound = createHash('sha256').update(attestKey).update(authData).digest();
  if (!bound.equals(qeReport.subarray(320, 352))) throw new Error('QE report does not bind the attestation key');
  if (!cryptoVerify('sha256', signed, { key: p256(attestKey), dsaEncoding: 'ieee-p1363' }, sig)) throw new Error('quote signature is wrong');
  return {
    body,
    tdAttributes: body.subarray(120, 128),
    mrConfigId: body.subarray(184, 232),
    rtmr3: body.subarray(472, 520),
    reportData: body.subarray(520, 584),
  };
}

type Event = { imr: number; event_type: number; event?: string; event_payload?: string; digest?: string };
const asJson = <T>(v: unknown): T => (typeof v === 'string' ? JSON.parse(v) : v) as T;

export function replayRtmr3(events: Event[]): Buffer {
  let rtmr = Buffer.alloc(48);
  for (const e of events) {
    if (e.imr !== 3) continue;
    const type = Buffer.alloc(4);
    type.writeUInt32LE(e.event_type);
    const digest = createHash('sha384').update(type).update(':').update(e.event ?? '', 'utf8').update(':').update(Buffer.from(e.event_payload ?? '', 'hex')).digest();
    if (e.digest && !Buffer.from(e.digest, 'hex').equals(digest)) throw new Error(`event digest is wrong: ${e.event}`);
    rtmr = createHash('sha384').update(rtmr).update(digest).digest();
  }
  return rtmr;
}

export type ReportCheck = { ok: boolean; signing_address: string; failure?: string };

/** One NEAR report (the gateway's or a model's): quote chain, debug off, nonce and signer in report data, measured config, RTMR3. */
export function checkReport(report: any, nonceHex: string, now: number): ReportCheck {
  const signing_address = String(report?.signing_address ?? '').toLowerCase();
  try {
    if (report?.signing_algo !== 'ecdsa') throw new Error('signing_algo is not ecdsa');
    if (String(report.request_nonce).toLowerCase() !== nonceHex.toLowerCase()) throw new Error('report echoes another nonce');
    const quote = verifyTdxQuote(report.intel_quote, now);
    if (quote.tdAttributes[0] & 1) throw new Error('TDX debug mode is on');
    const identity = Buffer.from(signing_address.replace(/^0x/, ''), 'hex');
    if (identity.length !== 20) throw new Error('signing address is not 20 bytes');
    const expected = Buffer.concat([identity, Buffer.alloc(12), Buffer.from(nonceHex, 'hex')]);
    if (!quote.reportData.equals(expected)) throw new Error('quote does not bind this signer and nonce');
    const tcb = asJson<any>(report.info?.tcb_info);
    const compose = createHash('sha256').update(String(tcb?.app_compose ?? ''), 'utf8').digest();
    if (!quote.mrConfigId.equals(Buffer.concat([Buffer.from([1]), compose, Buffer.alloc(15)]))) throw new Error('measured config does not match app_compose');
    if (!replayRtmr3(asJson<Event[]>(report.event_log)).equals(quote.rtmr3)) throw new Error('event log does not match RTMR3');
    return { ok: true, signing_address };
  } catch (e) {
    return { ok: false, signing_address, failure: (e as Error).message };
  }
}

// ---- the NEAR AI client: preflight attestation per model (cached), chat completions with exact bytes, response signatures

export type ModelProof = {
  model: string; ok: boolean; checked_at: string; nonce: string;
  gateway: ReportCheck | null; model_reports: ReportCheck[]; failure?: string;
};
export type SignatureCheck = { model: string; chat_id: string; ok: boolean; kind?: string; signer?: string; checked_at: string; failure?: string };
export type AttestationSnapshot = {
  provider: 'near-ai'; tier: 'Confidential TEE (NEAR-run)'; verify_url: string;
  models: ModelProof[]; last_signature: SignatureCheck | null; method: string[]; not_checked: string[];
};
export type NearClient = ReturnType<typeof createNear>;

export function createNear(opts: { apiKey: string; fetch?: typeof fetch; now?: () => number; nonce?: () => string }) {
  const base = config.nearai.url;
  const f = opts.fetch ?? ((...a: Parameters<typeof fetch>) => fetch(...a));
  const now = opts.now ?? Date.now;
  const proofs = new Map<string, { at: number; proof?: ModelProof; pending?: Promise<ModelProof> }>();
  let lastSignature: SignatureCheck | null = null;

  async function fetchProof(model: string): Promise<ModelProof> {
    const nonce = opts.nonce?.() ?? randomBytes(32).toString('hex');
    const at = now();
    const fail = (failure: string): ModelProof => ({ model, ok: false, checked_at: new Date(at).toISOString(), nonce, gateway: null, model_reports: [], failure });
    try {
      const qs = new URLSearchParams({ model, provider: 'near', include_tls_fingerprint: 'false', signing_algo: 'ecdsa', nonce });
      const res = await f(`${base}/attestation/report?${qs}`, {
        headers: { Accept: 'application/json', 'x-no-aliasing': 'true' },
        signal: AbortSignal.timeout(config.nearai.attestTimeoutMs),
      });
      if (!res.ok) return fail(`attestation report HTTP ${res.status}`);
      const body = await res.json() as any;
      const gateway = checkReport(body.gateway_attestation, nonce, at);
      const list: any[] = Array.isArray(body.model_attestations) ? body.model_attestations : [];
      // Instances of one model share one signing key, so the same report can come back several times.
      const unique = [...new Map(list.filter((m) => m?.model_name === model).map((m) => [String(m.signing_address).toLowerCase(), m])).values()];
      const model_reports = unique.map((m) => checkReport(m, nonce, at));
      const failure = !gateway.ok ? `gateway: ${gateway.failure}` : !model_reports.length ? 'no model report' : model_reports.find((m) => !m.ok)?.failure;
      return { model, ok: !failure, checked_at: new Date(at).toISOString(), nonce, gateway, model_reports, ...(failure ? { failure } : {}) };
    } catch (e) {
      return fail((e as Error).message);
    }
  }

  /** Starts a check when there is no fresh one. Never throws. */
  function refresh(model: string): Promise<ModelProof> {
    const entry = proofs.get(model);
    if (entry?.pending) return entry.pending;
    if (entry?.proof && now() - entry.at < config.nearai.attestTtlMs) return Promise.resolve(entry.proof);
    const pending = fetchProof(model).then((proof) => {
      proofs.set(model, { at: now(), proof });
      log('nearai_attestation', { model, ok: proof.ok, err: proof.failure });
      return proof;
    });
    proofs.set(model, { ...entry, at: entry?.at ?? 0, pending });
    return pending;
  }

  /** True when a fresh, passing check exists. A stale or missing check starts one in the background and reads false. */
  function attested(model: string): boolean {
    const entry = proofs.get(model);
    const fresh = entry?.proof && now() - entry.at < config.nearai.attestTtlMs;
    if (!fresh) void refresh(model);
    return !!(fresh && entry.proof!.ok);
  }

  async function checkSignature(model: string, chatId: string, request: string, response: string): Promise<SignatureCheck> {
    const at = new Date(now()).toISOString();
    const result = (r: Omit<SignatureCheck, 'model' | 'chat_id' | 'checked_at'>): SignatureCheck => ({ model, chat_id: chatId, checked_at: at, ...r });
    try {
      let sig: any;
      for (let attempt = 0; attempt < config.nearai.signatureTries; attempt++) {
        if (attempt) await new Promise((r) => setTimeout(r, config.nearai.signatureRetryMs));
        const res = await f(`${base}/signature/${encodeURIComponent(chatId)}?${new URLSearchParams({ model, signing_algo: 'ecdsa' })}`, {
          headers: { Accept: 'application/json', Authorization: `Bearer ${opts.apiKey}` },
          signal: AbortSignal.timeout(config.nearai.attestTimeoutMs),
        });
        if (res.status === 404) continue;
        if (!res.ok) return result({ ok: false, failure: `signature HTTP ${res.status}` });
        sig = await res.json();
        break;
      }
      if (!sig?.signature) return result({ ok: false, failure: 'no signature' });
      const hash = (s: string) => createHash('sha256').update(s, 'utf8').digest('hex');
      const proof = proofs.get(model)?.proof;
      const kind = String(sig.signature_kind ?? '');
      let expectedText: string, allowed: string[];
      if (kind === 'provider_tee') {
        expectedText = `${model}:${hash(request)}:${hash(response)}`;
        allowed = proof?.ok ? proof.model_reports.map((m) => m.signing_address) : [];
      } else if (kind === 'gateway') {
        expectedText = `${hash(request)}:${hash(response)}`;
        allowed = proof?.ok && proof.gateway ? [proof.gateway.signing_address] : [];
      } else {
        return result({ ok: false, kind, failure: 'unknown signature kind' });
      }
      if (sig.signing_algo !== 'ecdsa') return result({ ok: false, kind, failure: 'signing_algo is not ecdsa' });
      if (sig.text !== expectedText) return result({ ok: false, kind, failure: 'signed text does not match these bytes' });
      const signer = recoverEip191(sig.text, String(sig.signature));
      if (!signer || signer !== String(sig.signing_address).toLowerCase()) return result({ ok: false, kind, failure: 'signature does not recover to signing_address' });
      if (allowed.filter((a) => a === signer).length !== 1) return result({ ok: false, kind, signer, failure: 'signer is not the attested key' });
      return result({ ok: true, kind, signer });
    } catch (e) {
      return result({ ok: false, failure: (e as Error).message });
    }
  }

  /** One chat completion with the canonical model id. Keeps the exact bytes, then checks the signature in the background. */
  async function chat(model: string, body: Record<string, unknown>, timeoutMs: number, signal?: AbortSignal): Promise<{ content: string; signature: Promise<SignatureCheck> | null }> {
    const request = JSON.stringify({ ...body, model });
    const timeout = AbortSignal.timeout(timeoutMs);
    const res = await f(`${base}/chat/completions`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${opts.apiKey}`, 'Content-Type': 'application/json', 'x-no-aliasing': 'true', 'Accept-Encoding': 'identity' },
      body: request,
      signal: signal ? AbortSignal.any([signal, timeout]) : timeout,
    });
    if (!res.ok) throw new Error(`HTTP ${res.status} from ${new URL(base).host}`);
    const response = await res.text();
    const data = JSON.parse(response);
    const content = data?.choices?.[0]?.message?.content;
    if (typeof content !== 'string' || !content.trim()) throw new Error('empty completion');
    const id = typeof data.id === 'string' ? data.id : '';
    const signature = id && proofs.get(model)?.proof?.ok
      ? checkSignature(model, id, request, response).then((s) => {
        lastSignature = s;
        log('nearai_signature', { model, ok: s.ok, kind: s.kind, err: s.failure });
        return s;
      })
      : null;
    return { content, signature };
  }

  return {
    chat,
    attested,
    refresh,
    async snapshot(models: string[]): Promise<AttestationSnapshot> {
      return {
        provider: 'near-ai',
        tier: 'Confidential TEE (NEAR-run)',
        verify_url: 'https://cloud.near.ai/verify',
        models: await Promise.all(models.map(refresh)),
        last_signature: lastSignature,
        method: [
          'Fresh 32-byte nonce per check; GET /v1/attestation/report with x-no-aliasing',
          'Intel TDX quote: signature by the attestation key, QE report binding, PCK chain to the pinned Intel root CA',
          'TDX debug bit off; report data = signing address + our nonce, read from the quote',
          'MRCONFIGID = sha256(app_compose); RTMR3 = replayed event log',
          'Each reply: GET /v1/signature/<id>, EIP-191 signer must equal the attested model key and sign sha256 of the exact request and response bytes',
        ],
        not_checked: NOT_CHECKED,
      };
    },
  };
}
