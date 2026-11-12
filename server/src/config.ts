const env = process.env;

export const TONES = ['polite', 'professional', 'friendly', 'shorter', 'firmer'] as const;
export type Tone = (typeof TONES)[number];

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
  },

  jev: {
    url: 'https://api.typesafe.ai/v1/systemone',
    model: env.TYPESAFE_MODEL ?? 'jev-latest',
    timeoutMs: 4000,
    minConfidence: 0.6,
  },

  llm: {
    url: 'https://openrouter.ai/api/v1/chat/completions',
    timeoutMs: 2000,
    // Rewrites are longer than extraction, so they get more time before the backup model starts.
    writeTimeoutMs: 6000,
    writeHedgeMs: 1500,
    // A drawn scene is a few thousand tokens of JSON.
    explainTimeoutMs: 15_000,
    primary: { model: 'meta-llama/llama-3.3-70b-instruct', provider: { order: ['groq'], allow_fallbacks: true } },
    fallback: { model: 'google/gemini-2.5-flash' },
  },

  rateLimit: {
    suggest: { limit: 60, windowMs: 60_000 },
    write: { limit: 30, windowMs: 60_000 },
    // Explain and draw are paid calls a person asks for, so a few a minute and a cap per day.
    explain: { limit: 10, windowMs: 60_000 },
    explainDaily: { limit: 100, windowMs: 86_400_000 },
    shareUpload: { limit: 20, windowMs: 3_600_000 },
    // Opening a shared link needs no token, so it is limited per address.
    shareView: { limit: 120, windowMs: 60_000 },
    other: { limit: 120, windowMs: 60_000 },
    auth: { limit: 10, windowMs: 60_000 },
    // A device account needs no proof of who asks, so one address gets few of them.
    deviceAuth: { limit: 5, windowMs: 3_600_000 },
  },
};
