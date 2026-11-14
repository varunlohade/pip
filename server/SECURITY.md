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
- `GET /v1/auth/apple/nonce` gives a random 256-bit nonce that works once within 10 minutes. The server stores only a keyed hash. A nonce it never gave out is refused when `APPLE_NONCE_REQUIRED=1`, or with `NODE_ENV=production` unless `APPLE_NONCE_REQUIRED=0`.
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
- The rate limiter lives in memory, so it resets on restart and does not span instances. It keys IPv6 clients by /64. It drops ended windows first and the oldest live one only when it holds 100,000 keys; it never clears all.
- Passwords: scrypt N=2^16, r=8, p=2 (64 MB per hash). At most 2 hashes run at once; others wait up to 10 s, then get 503.
- Password tries live in SQLite (`auth_failures`), counted before the hash: 5 per (email, address) in 15 minutes, then 20 an hour per email with a delay that doubles up to 5 minutes.
- There is no key rotation yet. The `v1:` prefix leaves room for it.
- CORS allows no origins by default. Set `CORS_ORIGINS` for a web client.
- The server trusts `X-Forwarded-For` only with `TRUST_PROXY=1`, and then only the right-most hop. Behind Cloudflare, set `CLIENT_IP_HEADER=cf-connecting-ip`, because there the right-most hop is the Cloudflare edge.

## NEAR payments (testnet only, demo custody)
- Code: `server/src/pay/`. Library: `near-api-js` 7.5.3 (MIT AND Apache-2.0). Testnet only: the config refuses a mainnet RPC or a non-`.testnet` funder, the RPC must report `chain_id = testnet` before any key signs, and the parser refuses `.near` recipients.
- Flow: `POST /v1/pay/parse` (fixed patterns, recipient checked on chain) → `POST /v1/pay/intents` (exact amount, token, recipient; 10 minutes; deep link `pip://approve/<id>`) → the app shows a fixed card from `GET /v1/pay/intents/:id` → `POST /v1/pay/intents/:id/approve` or `/reject`. Also `GET /v1/pay/wallet`, `GET /v1/pay/history`, `POST /v1/pay/approver`.
- Approve needs the `X-Pay-Approver` key. The app makes it once (`POST /v1/pay/approver`) and keeps it in its own Keychain group, with no shared access group, so the keyboard's token alone cannot approve. The body must repeat the exact fields. Caps per payment and per rolling day are checked inside one SQLite transaction with the claim. The claim is single-use: a second approve returns the first result and never sends again. An unknown broadcast outcome is never retried; its tx hash is kept, since it is computed before broadcast.
- The app keeps the approver key in its own Keychain group (its application identifier, `WhenUnlockedThisDeviceOnly`), not in the group it shares with the keyboard. The app asks for Face ID (passcode fallback, `LAContext .deviceOwnerAuthentication`) before each approve; the Keychain item itself has no biometric access control. Logout and a new sign-in delete it.
- **Keyboard pay (design C).** One-time setup in the app (`POST /v1/pay/keyboard`, needs the approver key) sets daily keyboard limits and returns a second key, `pkb_…`. The app puts that key in the shared Keychain group, so the keyboard can read it. `POST /v1/pay/intents/:id/keyboard-approve` takes it in `X-Pay-Keyboard`. The server caps it: only recipients this user already paid (a `sent` intent), and only up to the keyboard's daily limit (sends with `via = 'keyboard'` in the last 24 h), checked inside the same transaction as the claim, and never above the server's own caps. Anything else answers 403 with `needs_app`, and the keyboard opens the app card. The keyboard key cannot call `/approve`, cannot make or change keyboard limits, and is only ever stored as a hash. `DELETE /v1/pay/keyboard` (approver key) turns it off. Face ID in the keyboard is the owner's choice (on by default); if the keyboard cannot run it, the payment goes to the app.
- **A fake keyboard can copy the keyboard card.** Any third-party keyboard can draw the same amount, recipient, badge and "Approve with Face ID" button, and the system Face ID sheet does not say which app asked. A look-alike can't send money without our keyboard key, but the keyboard key is only as safe as the shared Keychain group and the phone. That is why the server, not the keyboard, enforces the limits: a stolen or misused keyboard key can at most send the daily keyboard limit to people the owner already paid. A new recipient always opens Pip, where the card is drawn by the app itself and approve needs the app-only key.
- **Custody: the server holds each user's testnet key.** Each user gets a sub-account of the funder (`pip-<hash>.<funder>`) with 0.2 testnet NEAR. Its full-access key is stored AES-GCM encrypted with the per-user data key above. Risks: anyone with `DATA_ENCRYPTION_KEY` and the database can move every wallet's funds; a server bug in the approve gate could send without the user. This is acceptable only because testnet tokens have no value.
- **Mainnet would not work this way.** Signing moves to the user: a passkey (WebAuthn) signs a NEAR Intents message on the phone, the server only relays, and approval *is* the signature (`docs/NEAR-PLAN.md` section 2.2, path B). The server then holds no user key at all.
- Env: `PAY_FUNDER_ACCOUNT_ID`, `PAY_FUNDER_PRIVATE_KEY` (a funded `.testnet` account; without them wallet and approve answer 503). Optional: `NEAR_RPC_URL`, `PAY_USDC_CONTRACT` (default: Circle testnet USDC), `PAY_MAX_PER_TX_NEAR`/`_DAILY_NEAR` (1/2), `PAY_MAX_PER_TX_USDC`/`_DAILY_USDC` (10/25), `PAY_NEW_WALLET_NEAR` (0.2), `PAY_MAX_WALLETS` (100).
- Manual steps: a funder account came from the keyless testnet helper (`POST https://helper.nearprotocol.com/account`, 10 testnet NEAR). Testnet USDC needs Circle's faucet (faucet.circle.com, choose NEAR testnet) sent to a wallet's account id. Live check: `node scripts/pay-testnet-demo.ts` with the funder env set.
