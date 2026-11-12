# Pip auth: design and security review

## How sign-in works

- **Ways in.** Each of these works alone:
  - Sign in with Apple;
  - email + password;
  - "Skip for now", which makes a device account.

  A device account can add Apple or an email later and keeps its user id, so nothing is lost. An Apple user can add an email and password, and an email user can add Apple.
- **Sessions.** Each session has a 15-minute access token (`pat_`) and a 30-day refresh token (`prt_`). Each refresh spends the old refresh token and returns a new pair. A spent token that comes back means a copy leaked, so the server deletes the whole session (the family). The server stores only SHA-256 hashes of tokens. The API takes bearer tokens only, so CSRF does not apply. CORS allows no origin by default.
- **Passwords.**
  - Hashed with scrypt (N=2^15, r=8, p=1). The cost travels with the hash.
  - At least 10 characters, normalized to NFC.
  - Checked against a short common-password list, and must not contain the email's local part.
- **Emailed codes.**
  - A code is 6 digits, works for 15 minutes, and allows 5 wrong tries.
  - Wrong tries also count per user across all codes: after 10 a day, no code works.
  - Codes go through the `Mailer` interface. The only mailer, `createDevMailer`, sends nothing and logs only the kind. With `MAIL_DEV_PRINT=1` outside production, it also prints the code.
- **No enumeration.**
  - Sign-up, forgot and link always answer `202 {"status":"check_email"}`.
  - Sign-in answers `401 wrong email or password` for an unknown email, a wrong password and an unconfirmed account alike.
  - An unknown email still runs a full scrypt hash against a dummy hash.
  - Mail goes out without the reply waiting for it.
- **Brute force.**
  - Per client IP: 20 email-auth calls a minute.
  - Per email (known or unknown): after 5 misses, a 30 s lock that doubles with each miss, up to an hour. A miss is counted before the hash, so parallel guesses meet the lock.
  - Per email: 5 mails an hour.
- **Logout.**
  - Log out ends this session.
  - Log out everywhere ends every session, legacy device token and live code.
  - Delete account deletes the user, and every per-user table cascades. An account with a password must send it.

  On the phone, all three run the full wipe in `docs/DATA.md`.

## Review 1: server (fresh security-researcher agent, read-only, with in-process PoCs)

| # | Finding | Severity | Fix | Test |
|---|---|---|---|---|
| F1 | A second sign-up for an unconfirmed email replaced its password. The victim then confirmed with the attacker's password set. | High | Sign-up never touches an existing password. `/email/verify` takes the password with the code, and only the code holder can confirm. | `auth.test.ts` F1 |
| F2 | Each forgot call made a fresh code with fresh tries, even over the mail limit. | High | Over the mail limit, no code is made. 10 wrong codes a day per user stop every code. | F2 |
| F3 | Parallel wrong passwords all passed the lock check before any miss was counted. | Medium | The miss is counted before the slow hash and cleared on success. | F3 |
| F4 | Sign-in told a new email (403) from a confirmed one (401). | Medium | An unconfirmed account answers like a wrong password. | F4 |
| F5 | The rate limiter cleared every key at 10,000 keys, so one client could reset everyone. | Medium | It drops ended windows first, then the oldest, and never everything. | F5 |
| F6 | Forgot and verify took slightly different times for known and unknown emails (in-process, about 50 µs). | Low | Both paths now compute the code HMAC. The rest is DB time, behind a 20/min IP limit. | none (a timing test this small would be flaky) |
| F7 | Log out everywhere left live codes. Deleted rows could stay in free pages. | Low | Codes go too, and `PRAGMA secure_delete = ON`. | F7 |
| F8 | A captured Apple token and nonce could be replayed until `exp`, and `iat` was not checked. | Low | Each nonce works once (`used_nonces`, migration 3). A future `iat` is refused. | `apple.test.ts` F8 |
| F9 | A 15-minute access token alone could delete the account. | Low | Password accounts must send the password, and a wrong one counts toward the lockout. | F9 |
| F10 | If the app and the keyboard refreshed at once, the reuse check logged the person out. | Info | The phone refreshes under an `flock` in the App Group (see review 2, F2). | `WipeRaceTests` |

Checks that passed: token theft and replay (hashes only, rotation drops old access tokens, `pkd_` tokens trade once), reuse detection, CSRF and CORS, logs (redaction covers email, password, code, token and nonce, and `auth.test.ts` checks a whole flow), mass assignment (strict schemas), SQL injection (parameters only), and the Apple checks (RS256, kid, iss, aud, exp, nonce).

## Review 2: iOS (fresh security-researcher agent, read-only)

| # | Finding | Severity | Fix | Test |
|---|---|---|---|---|
| F1 | Keychain items outlive an uninstall. A reinstall opened as the previous person. | Medium | A fresh install (no marker and no App Group data) drops the Keychain group, in both the app and the keyboard. | `WipeRaceTests.testAFreshInstallDropsSecretsAnEarlierInstallLeft` |
| F2 | A refresh in flight during a logout could save the last person's new tokens. The wipe also deleted the lock file. | Low-Medium | The refresh saves only if the account epoch did not change. The wipe takes the lock when it is free within 1 s and never deletes the lock file. | `testARefreshThatFinishesAfterALogoutDoesNotSaveTheLastPersonsTokens` |
| F3 | A keyboard that stayed on screen across a logout kept, and could save, the last person's notes. | Low | The epoch is checked on every text change and in Notes. | `PersonaTests.testSwitchingPeopleWhileTheKeyboardStaysUp` (now without `keyboardAppeared`) |
| F4 | Release `DEFAULT_SERVER_URL` is `http://localhost:8787` with local networking allowed. | Low | **Not fixed here.** Pip has no hosted server yet. Before shipping, set an HTTPS URL and fail the build on `http://`. | none |
| F5 | The nonce ignored the result of `SecRandomCopyBytes`. | Info | `SystemRandomNumberGenerator`. | covered by the sign-in UI test path |
| F6 | The keyboard's on-disk caches wait until its next use. | Info | Accepted. The API uses POST (which URLCache does not store), and the web views are non-persistent. | `WipeTests.testTheKeyboardForgetsThePreviousPersonOnItsNextAppearance` |

## Known gaps

- The IP and mail rate limiters live in memory: they reset on restart and do not span instances. The per-email lockout and the code caps are in SQLite.
- With `TRUST_PROXY=1` and `CLIENT_IP_HEADER`, the IP limits rely on the proxy setting that header. If the origin can be reached directly, the header can be spoofed.
- No real mailer yet, so email sign-up cannot be finished in production until one is plugged in behind `Mailer`.
- An Apple-only or device account deletes with a confirm alone (it has no password to ask for).
- Server logs keep user ids (never emails, tokens or codes).
- Review 2 was read-only. Uninstall behaviour on a real device was not tested; the simulator unit test stands in for it.
