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

## NEAR payments: legacy server-held testnet path (off by default)
- This path is legacy. It runs only with `PAY_LEGACY_CUSTODY=1`; otherwise `GET /v1/pay/wallet` and `approve` belong to the phone-signed flow below, and a legacy approve answers 410.
- Code: `server/src/pay/`. Library: `near-api-js` 7.5.3 (MIT AND Apache-2.0). Testnet only: the config refuses a mainnet RPC or a non-`.testnet` funder, the RPC must report `chain_id = testnet` before any key signs, and the parser refuses `.near` recipients.
- Flow: `POST /v1/pay/parse` (fixed patterns, recipient checked on chain) → `POST /v1/pay/intents` (exact amount, token, recipient; 10 minutes; deep link `pip://approve/<id>`) → the app shows a fixed card from `GET /v1/pay/intents/:id` → `POST /v1/pay/intents/:id/approve` or `/reject`. Also `GET /v1/pay/wallet`, `GET /v1/pay/history`, `POST /v1/pay/approver`.
- Approve needs the `X-Pay-Approver` key. The app makes it once (`POST /v1/pay/approver`) and keeps it in its own Keychain behind Face ID, with no shared access group, so the keyboard's token alone cannot approve. The body must repeat the exact fields. Caps per payment and per rolling day are checked inside one SQLite transaction with the claim. The claim is single-use: a second approve returns the first result and never sends again. An unknown broadcast outcome is never retried; its tx hash is kept, since it is computed before broadcast.
- **Custody: the server holds each user's testnet key.** Each user gets a sub-account of the funder (`pip-<hash>.<funder>`) with 0.2 testnet NEAR. Its full-access key is stored AES-GCM encrypted with the per-user data key above. Risks: anyone with `DATA_ENCRYPTION_KEY` and the database can move every wallet's funds; a server bug in the approve gate could send without the user. This is acceptable only because testnet tokens have no value.
- **Superseded** by the phone-held key flow below, which runs on testnet and mainnet.
- Env: `PAY_FUNDER_ACCOUNT_ID`, `PAY_FUNDER_PRIVATE_KEY` (a funded `.testnet` account; without them wallet and approve answer 503). Optional: `NEAR_RPC_URL`, `PAY_USDC_CONTRACT` (default: Circle testnet USDC), `PAY_MAX_PER_TX_NEAR`/`_DAILY_NEAR` (1/2), `PAY_MAX_PER_TX_USDC`/`_DAILY_USDC` (10/25), `PAY_NEW_WALLET_NEAR` (0.2), `PAY_MAX_WALLETS` (100).
- Manual steps: a funder account came from the keyless testnet helper (`POST https://helper.nearprotocol.com/account`, 10 testnet NEAR). Testnet USDC needs Circle's faucet (faucet.circle.com, choose NEAR testnet) sent to a wallet's account id. Live check: `node scripts/pay-testnet-demo.ts` with the funder env set.

## NEAR payments: phone-held keys (testnet and mainnet)
- Code: `server/src/pay/phone/` and `server/src/pay/network.ts`. Pip is self-custodial: the app holds the key on every network. **The server never holds a user key and has no mainnet key at all.** It only builds the unsigned transaction, checks the phone's signature, and broadcasts.
- Key: the app makes an Ed25519 key with CryptoKit (`Curve25519.Signing.PrivateKey`) and stores it in the app's own Keychain item with `kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly` and `SecAccessControl` `.biometryCurrentSet` (Face ID for every signature). No shared access group, so the keyboard extension cannot read it. The key never leaves the phone; there is no server backup, so a lost phone loses the key (export/recovery is not built yet).
- Account: the implicit account of that key (the 32 public-key bytes in hex). `POST /v1/pay/register {publicKey}` (app only: `X-Pay-Approver`) records it for the user's current network. One key per user per network; one user per account id. On testnet the funder sends `PAY_NEW_WALLET_NEAR` once (free test money, counted against `PAY_MAX_WALLETS`). On mainnet the user funds it; the server sends nothing.
- Network: `GET/PUT /v1/pay/network` (testnet default; the switch is app only). Mainnet is off unless `PAY_MAINNET=1`. The RPC must report `chain_id` equal to the chosen network before any broadcast or funding.
- Flow: `POST /v1/pay/intents` (exact fields, per-tx cap, 10 minutes; mainnet takes `.near` and implicit ids only, never `.testnet`) → `POST /v1/pay/intents/:id/unsigned` (same exact fields again; a recipient never paid before needs the app key) → the server builds one transaction (access-key nonce + 1, above any nonce it built before; a final block hash; `Transfer`, or USDC `ft_transfer` with 1 yoctoNEAR, preceded by `storage_deposit` when `storage_balance_of` is null) and stores the bytes → the app signs the 32-byte `sha256(tx)` with Face ID → `POST /v1/pay/intents/:id/submit {signature}` → the server checks the Ed25519 signature against the registered key over the stored bytes, claims the intent once, and broadcasts.
- Caps per network, per payment and per rolling day, in one SQLite transaction with the build. A built but unsigned tx counts until its intent expires. Mainnet defaults: 2 NEAR / 5 NEAR a day, 10 USDC / 20 USDC a day (`PAY_MAINNET_MAX_PER_TX_*`, `PAY_MAINNET_MAX_DAILY_*`). The caps guard the server's flow; the phone holds the key, so it could always sign outside Pip.
- Idempotent: `unsigned` twice returns the same bytes; `submit` after a send returns the first result. An unknown broadcast outcome is kept with its tx hash and never rebuilt or resent.
- Risks: a server bug could build a tx that differs from the card; the app must decode `tx_base64` and show receiver, amount and actions from the bytes before Face ID. The server's DB holds public keys and unsigned bytes only. Library: `near-api-js` 7.5.3 (MIT AND Apache-2.0).
