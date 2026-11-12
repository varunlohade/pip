# Security

## What we store
- Users and their sessions. We store only SHA-256 hashes of access and refresh tokens. Full table list: `docs/DATA.md`.
- Emails as a keyed hash (for lookup) plus AES-GCM ciphertext; passwords as scrypt hashes. Auth design and review: `docs/SECURITY-AUTH.md`.
- Apple user ids (`sub`): we store only a keyed hash, `HMAC-SHA256(HKDF(DATA_ENCRYPTION_KEY, info = "pip/index/v1"), sub)`. We ask Apple for no name and no email.
- We do not store typed text. `/v1/suggest` and `/v1/write/*` read it, send it to the models, and drop it.

## Shared drawings ("Send as link")
- `POST /v1/drawings` takes one PNG (checked by its magic bytes), at most 1 MB, 20 an hour per user.
- The id is 128 random bits (`/d/<22 base64url chars>.png`). It holds nothing about the user or the time, and no route lists ids.
- `GET /d/<id>.png` needs no token: whoever has the link sees the image, served as `image/png` with `nosniff` and `default-src 'none'`, and nothing else. 120 views a minute per address.
- A link works for 30 days. Expired rows are deleted on the next upload, and an expired id answers like an unknown one (404).
- The image itself is not encrypted at rest: anyone with the link may see it, by design.

## Encryption helper
- `crypto.ts` has an AES-256-GCM cipher for any per-user field that needs it: a random 12-byte IV per record, a 16-byte auth tag. Format: `v1:base64(iv | tag | ciphertext)`.
- Each user gets their own data key: `HKDF-SHA256(DATA_ENCRYPTION_KEY, salt = user_id, info = "pip/data/v1")`.
- The `user_id` is the GCM additional data. A row copied to another user fails to decrypt.

## Key handling
- `DATA_ENCRYPTION_KEY` is 32 random bytes (64 hex chars) in `.env`. `npm run setup` creates it if it is missing and never prints it.
- `.env` is git-ignored with mode 0600. Secrets come only from the environment.
- No key goes to any model. The models get only the message text.
- Logs redact keys that look like tokens, secrets, names, emails or text. Writing help logs only sizes and timings.

## Sign in with Apple
- `POST /v1/auth/apple` takes the identity token and the raw nonce. It runs before the device token check.
- The server checks the RS256 signature against Apple's keys (`https://appleid.apple.com/auth/keys`, cached for a day), then `iss`, `aud` (`APPLE_BUNDLE_ID`, default `com.orseliyas.pip`), `exp`, and that the token's `nonce` is the SHA-256 of the raw nonce.
- Every failure returns the same `401 {"error":"unauthorized"}`. The reason goes only to the server log. The token never goes to the log.
- A good token finds or creates the user and returns a session (access + refresh token). Each nonce works once. The limit is 10 calls a minute per client IP.
- `POST /v1/auth/device` makes a new user on every call and never looks up the device id. The limit is 5 an hour per client IP.

## Per-user access
- An access token maps to one session and one `user_id`. One user can have several sessions.
- Every route reads the `user_id` from the token, never from the request body.

## Threat model
1. **Stolen DB file.** The DB holds only hashes of tokens and Apple ids.
2. **Stolen or guessed token.** Tokens have 256 random bits. The DB has only hashes. Access tokens last 15 minutes; a reused refresh token ends its session.
3. **Prompt injection in chat text.** The model only picks a chip kind or rewrites text. Writing help runs only with `X-User-Action: tap`, and a rewrite must stay close to the size of its input.

## Known gaps
- The rate limiter lives in memory, so it resets on restart and does not span instances.
- There is no key rotation yet. The `v1:` prefix leaves room for it.
- CORS allows no origins by default. Set `CORS_ORIGINS` for a web client.
- The server trusts `X-Forwarded-For` only with `TRUST_PROXY=1`, and then only the right-most hop. Behind Cloudflare, set `CLIENT_IP_HEADER=cf-connecting-ip`, because there the right-most hop is the Cloudflare edge.
