# Where Pip keeps data

This page lists every place Pip stores data, on the server and on the phone, and what a logout or an account delete removes.

## Server (SQLite, `server/src/db.ts`)

### Migrations

`PRAGMA user_version` holds the number of migrations that ran. On start, `openDb` runs the rest in order. Each one runs in a transaction, followed by `PRAGMA foreign_key_check`. Never edit a migration that shipped; add a new one.

| # | What it does |
|---|---|
| 1 | The first schema: `users`, `devices`, `shared_images`. Databases from before migrations start at 0 and already hold most of it. |
| 2 | Rebuilds `devices` and `shared_images` with `ON DELETE CASCADE`. Adds the email and password columns. Adds `sessions`, `refresh_tokens`, `access_tokens`, `email_codes` and `login_failures`. |
| 3 | Adds `used_nonces`, so each Sign in with Apple nonce works once. |
| 4 | Adds `apple_nonces`, the nonces the server gave out. |

Foreign keys are on, and `secure_delete` is on, so SQLite overwrites deleted rows with zeros.

### Tables

| Table | One row per | Personal data, and how it is stored |
|---|---|---|
| `users` | person | `apple_sub_hash`: a keyed hash of the Apple user id. `email_hash`: a keyed hash of the lowercase email, used for lookup. `email_enc`: the email, AES-256-GCM with the user's own key. `password_hash`: scrypt. No plaintext email. |
| `sessions` | sign-in on one phone | user id and a label ("email", "apple", "device"). |
| `refresh_tokens` | refresh token | SHA-256 of the token only. Spent tokens stay until they expire, so a reuse is caught. |
| `access_tokens` | access token | SHA-256 of the token only. Each lasts 15 minutes. |
| `email_codes` | live code per user and purpose | A keyed hash of the code. For "link", it also holds the new email (hash plus ciphertext) and its scrypt hash until the code is used. |
| `login_failures` | email hash, or `code:<user id>` | Counts and lock times. It holds no email. |
| `devices` | legacy device token | SHA-256 of an old `pkd_` token, until it is traded for a session once. |
| `shared_images` | drawing shared as a link | The PNG, its JPEG preview and the title. These are not encrypted, because anyone with the link may see them. |
| `used_nonces` | Apple sign-in | A keyed hash of the nonce, kept until the identity token would expire. |
| `apple_nonces` | `GET /v1/auth/apple/nonce` | A keyed hash of each nonce the server gave out, its expiry (10 minutes) and whether it is used. Kept an hour past expiry. |

Every per-user table points at `users(id)` with `ON DELETE CASCADE`, directly or through `sessions`. `DELETE FROM users WHERE id = ?` removes everything that belongs to the person. The delete route also removes the person's `login_failures` rows.

### Keys

`DATA_ENCRYPTION_KEY` (32 bytes, in `.env`) is the master key. From it, `crypto.ts` derives these keys:
- a per-user data key: `HKDF(master, salt = user id, info = "pip/data/v1")`, for `email_enc`. The user id is also the GCM additional data, so a row copied to another user does not decrypt.
- one index key: `HKDF(master, info = "pip/index/v1")`, for the keyed lookup hashes (`email`, `apple-sub`, `code`, `apple-nonce` scopes).

### What each action removes

| Action | Server |
|---|---|
| Log out | This session, its access tokens and its refresh tokens. |
| Log out everywhere | Every session of the user, every legacy device token, and every live emailed code. |
| Password reset | Every session (then a new one starts). |
| Delete account (password accounts must send the password) | The user row and, by cascade, every row above. Shared links answer 404. |

## Phone (`ios/Shared/SharedStore.swift`)

One storage layer for the app and the keyboard. Every key is declared in one place.

### Keychain (`Secret`)

These are generic passwords with service `com.orseliyas.pip.device` in the shared access group `<TeamID>.com.orseliyas.pip.shared`. They are `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: readable after the first unlock, never in backups, never synced.

| Key | What |
|---|---|
| `access_token` | 15-minute access token |
| `refresh_token` | rotating refresh token |
| `device_token` | a legacy token, traded once on launch and then deleted |
| `device_id` | a random id for this install |

No secret lives in UserDefaults or in a file.

### App Group defaults (`StoreKey`)

`server_url`, `pasteboard_change_count`, `apple_linked`, `keyboard_last_seen`, `account_epoch`, `keyboard_seen_epoch`. None is secret.

### App Group files (`StoreFile`)

`appointments.json`, `notes.json`, `shortcuts.json`, `drawings.json` plus the `drawings/` folder (PNG and scene JSON), `learned.json` (words and answers looked up), `caught.json` (plans read in chats), and `refresh.lock` (an empty lock file).

All of them are written with `completeUntilFirstUserAuthentication`. The keyboard can then read them while the phone is locked, once it has been unlocked after a restart.

### Token refresh

When an access token is rejected, the API client refreshes once and retries. The refresh holds an `flock` on `refresh.lock` in the App Group. The app and the keyboard therefore never spend one refresh token twice. If the server reads a second spend as theft, it ends the session.

### Logout and delete on the phone (`ios/Shared/LocalWipe.swift`)

The app wipes these, in this order:
1. Every Keychain item in the shared group.
2. Every App Group file and folder, one by one, plus everything in the group's `Library` except `Preferences`. iOS's `.com.apple.mobile_container_manager.metadata.plist` and the refresh lock file stay.
3. Every App Group default, key by key.
4. A new `account_epoch`.
5. The app's `URLCache`.
6. Its cookies, in both the shared and the group stores.
7. Every `WKWebsiteDataStore` data type.
8. Its temp folder and its caches.
9. Its own UserDefaults.

The keyboard runs in its own process with its own sandbox. On its next appearance it compares `account_epoch` with `keyboard_seen_epoch`. If they differ, it throws its model away and builds a new one. The old model first drops what it holds in memory:
- notes;
- cached answers;
- the prepared drawing and preview;
- smart chips;
- writing state.

It then wipes its own URL cache, cookies, web data, temp files, caches and defaults.

The same wipe runs when the server answers 401 on any route outside `/v1/auth/`. Then the app opens the sign-in step with a new navigation stack.

`ios/Tests/WipeTests.swift` seeds every store above, logs out through `Session.leave(.logout)` and checks that each one is empty. `ios/Tests/PersonaTests.swift` passes ten people through one keyboard and checks that no one sees the last person's data.
