const env = process.env;

export const TONES = ['polite', 'professional', 'friendly', 'shorter', 'firmer'] as const;
export type Tone = (typeof TONES)[number];
/** The versions the rewrite list streams: every tone, then the grammar fix. */
export const REWRITES = [...TONES, 'fix'] as const;
export type Rewrite = (typeof REWRITES)[number];

/** A NEAR model id. Pip never sends text to Claude or GPT models, so those ids are refused at start-up. */
function teeModel(id: string): string {
  if (/anthropic|claude|openai|gpt/i.test(id)) throw new Error(`refusing model ${id}: Pip does not route to Claude or GPT`);
  return id;
}

export const config = {
  port: Number(env.PORT ?? 8787),
  dbPath: env.DB_PATH ?? new URL('../data/pip.db', import.meta.url).pathname,
  corsOrigins: (env.CORS_ORIGINS ?? '').split(',').map((s) => s.trim()).filter(Boolean),
  trustProxy: env.TRUST_PROXY === '1',
  // Behind Cloudflare (Render), X-Forwarded-For ends with the Cloudflare edge, so read the header Cloudflare sets instead.
  clientIpHeader: (env.CLIENT_IP_HEADER ?? '').trim().toLowerCase(),
  bodyLimitBytes: 16 * 1024,
  maxTextChars: 2000,
  maxContextChars: 1000,
  maxWriteChars: 1500,
  maxExplainChars: 200,
  // "Send as link": a drawing PNG kept for 30 days at an unguessable URL. PUBLIC_URL is the address people open; else the request's own origin.
  // The phone also sends a small JPEG for chat link previews (WhatsApp drops big ones). An expired link answers 410 for a year, then 404.
  sharedImage: {
    maxBytes: 1024 * 1024, ttlMs: 30 * 86_400_000, keepGoneMs: 365 * 86_400_000,
    preview: { maxBytes: 300 * 1024, minWidth: 600, maxSide: 4096 },
    maxTitleChars: 80,
  },
  publicUrl: (env.PUBLIC_URL ?? '').replace(/\/+$/, ''),

  apple: {
    // The app bundle id. Apple puts it in the identity token as aud.
    audience: env.APPLE_BUNDLE_ID ?? 'com.orseliyas.pip',
    issuer: 'https://appleid.apple.com',
    jwksUrl: 'https://appleid.apple.com/auth/keys',
    jwksTtlMs: 24 * 60 * 60 * 1000,
    jwksMinRefetchMs: 60_000,
    timeoutMs: 5000,
    // GET /v1/auth/apple/nonce gives a single-use nonce for this long. When required, a nonce the server never gave out is
    // refused: with APPLE_NONCE_REQUIRED=1, or in production unless APPLE_NONCE_REQUIRED=0.
    nonceTtlMs: 10 * 60_000,
    requireServerNonce: env.APPLE_NONCE_REQUIRED === '1' || (env.NODE_ENV === 'production' && env.APPLE_NONCE_REQUIRED !== '0'),
  },

  // scrypt uses 64 MB per hash. At most this many run at once, so a small server does not run out of memory.
  // The others wait up to queueTimeoutMs, then get 503 with Retry-After.
  password: { maxConcurrent: 2, queueTimeoutMs: 10_000 },

  auth: {
    // A short access token and a rotating refresh token. Each refresh spends the old refresh token; a spent one coming back
    // means a copy leaked, so the whole session (its family) is deleted.
    accessTtlMs: 15 * 60_000,
    refreshTtlMs: 30 * 86_400_000,
    // Emailed 6-digit codes: 15 minutes, 5 wrong tries, then a new code is needed.
    codeTtlMs: 15 * 60_000,
    codeMaxAttempts: 5,
    // Wrong codes per user per day, across all codes. Then no code works until the day ends.
    codeDailyMisses: 10,
    // Password tries, counted before the hash. One client address gets 5 tries per email in 15 minutes, then waits 15 minutes:
    // that address alone, so a stranger cannot lock the owner out. Across all addresses an email gets 20 tries an hour;
    // after that each try waits longer (1 s, 2 s, 4 s ... up to 5 minutes), so slow guessing from many addresses still slows down.
    lockout: { perIpMax: 5, perIpWindowMs: 15 * 60_000, perIpLockMs: 15 * 60_000, perEmailMax: 20, perEmailWindowMs: 60 * 60_000, maxDelayMs: 5 * 60_000 },
    // Wrong emailed codes per user count over a day.
    failureWindowMs: 86_400_000,
  },

  jev: {
    url: 'https://api.typesafe.ai/v1/systemone',
    model: env.TYPESAFE_MODEL ?? 'jev-latest',
    timeoutMs: 4000,
    minConfidence: 0.6,
    // jev as listed on NEAR AI Cloud (same /systemone shape). Not attested: it does not run in a TEE.
    nearModel: env.NEARAI_JEV_MODEL ?? 'typesafe/jev-1.13',
    // /v1/route answers a label only at this confidence or more, else "none". From scripts/route-eval.ts (2026-11-14, 162 lines):
    // every label reached 0.9 precision at any confidence; 0.6 drops the one low miss ("what time" -> calendar_event at 0.47).
    routeMin: { default: 0.6 } as Record<string, number>,
  },

  llm: {
    url: 'https://openrouter.ai/api/v1/chat/completions',
    timeoutMs: 2000,
    // Rewrites are longer than extraction, so they get more time before the backup model starts.
    writeTimeoutMs: 6000,
    writeHedgeMs: 1500,
    // The streamed rewrite list: a version with no answer by then is skipped, and the phone offers Retry for it.
    rewriteStallMs: 4000,
    // A drawn scene is a few thousand tokens of JSON.
    explainTimeoutMs: 15_000,
    primary: { model: 'meta-llama/llama-3.3-70b-instruct', provider: { order: ['groq'], allow_fallbacks: true } },
    fallback: { model: 'google/gemini-2.5-flash' },
  },

  // NEAR AI Cloud private inference. Used when NEARAI_API_KEY is set; OpenRouter stays as the fallback.
  // Both default models run on NEAR's own TEE GPUs ("Confidential TEE" tier) and support attestation and JSON mode.
  nearai: {
    url: (env.NEARAI_URL || 'https://cloud-api.near.ai/v1').replace(/\/+$/, ''),
    primary: teeModel(env.NEARAI_MODEL_PRIMARY || 'Qwen/Qwen3.6-35B-A3B-FP8'),
    fallback: teeModel(env.NEARAI_MODEL_FALLBACK || 'z-ai/glm-5.3-flash'),
    // Extra body fields per model: JSON mode on, reasoning off or minimal, so a keyboard rewrite stays fast.
    params: {
      'Qwen/Qwen3.6-35B-A3B-FP8': { response_format: { type: 'json_object' }, chat_template_kwargs: { enable_thinking: false } },
      'z-ai/glm-5.3-flash': { response_format: { type: 'json_object' }, reasoning_effort: 'low' },
    } as Record<string, Record<string, unknown>>,
    // A passing attestation counts for this long; then the next request starts a new check in the background.
    attestTtlMs: 10 * 60_000,
    attestTimeoutMs: 10_000,
    signatureTries: 3,
    signatureRetryMs: 1000,
  },

  rateLimit: {
    suggest: { limit: 60, windowMs: 60_000 },
    write: { limit: 30, windowMs: 60_000 },
    // One rewrite starts a model call per version, so it has its own, smaller limit on top of write.
    rewrite: { limit: 10, windowMs: 60_000 },
    // Explain and draw are paid calls a person asks for, so a few a minute and a cap per day.
    explain: { limit: 10, windowMs: 60_000 },
    explainDaily: { limit: 100, windowMs: 86_400_000 },
    // One jev question per typing pause; the phone cancels on new typing.
    route: { limit: 60, windowMs: 60_000 },
    shareUpload: { limit: 20, windowMs: 3_600_000 },
    // Opening a shared link needs no token, so it is limited per address.
    shareView: { limit: 120, windowMs: 60_000 },
    other: { limit: 120, windowMs: 60_000 },
    auth: { limit: 10, windowMs: 60_000 },
    // Email sign-up, sign-in, codes and reset, per client IP. The per-email lockout sits on top.
    emailAuth: { limit: 20, windowMs: 60_000 },
    // Emails out per address, so nobody floods an inbox with codes.
    mailPerEmail: { limit: 5, windowMs: 3_600_000 },
    refresh: { limit: 30, windowMs: 60_000 },
    // A device account needs no proof of who asks, so one address gets few of them.
    deviceAuth: { limit: 30, windowMs: 3_600_000 },
  },
};
