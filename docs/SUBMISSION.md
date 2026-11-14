# NEAR HACKATHON submission (draft)

Deadline: 2026-11-14 23:59 UTC. One submission per project. Boss man checks every field and sends it. Do not commit the final payload; it holds personal data.

| Field | Draft value |
| --- | --- |
| projectName | Pip |
| leadName | TODO (Boss man) |
| email | TODO (Boss man) |
| size | TODO (Boss man): `1`, `2 - 4`, … |
| tracks | `["privacy", "realworld", "agents", "open"]` |
| nearAddress | TODO (Boss man): a mainnet account for the payout. Never invent one. |
| projectUrl | https://github.com/varunlohade/pip (must be public before the deadline; it is private today) |
| demoUrl | TODO (Boss man): link to the X post with the video |
| idea | see below |
| consent | TODO (Boss man reads the notice and agrees) |

Track notes:

- `privacy`: TEE inference on NEAR AI Cloud with our own attestation checks and a proof screen. Strongest fit.
- `realworld`: type-to-pay NEAR and USDC from any chat, with caps and a known-recipient rule.
- `agents`: optional. The keyboard acts for you, but within limits; it does not earn or hire other agents. Drop it if Boss man wants only strong fits.
- `open`: a keyboard as the place where money and AI meet.

## idea (about 1,500 characters)

```
Problem: the useful next step after a message is always in another app. You type "coffee at 3:30" and then open the calendar. You type "I'll send you 5 USDC" and then open a wallet, copy an address, and switch back. And when an AI helps you write, your private messages go to a model host you can't see.

Pip is an iPhone keyboard that does the next step where you type, in any app. It checks your calendar and warns about clashes, adds events and reminders, rewrites messages, explains a topic with a drawing, and sends money.

How NEAR fits in:
1) Private AI. Rewrites and explanations run on NEAR AI Cloud models inside a TEE (Intel TDX + NVIDIA). Our server checks NEAR's attestation itself: the TDX quote up to Intel's root, a fresh nonce, the debug bit, the measured config and event log, and a per-reply signature from the attested model key. The app shows a "Private AI" mark and a proof screen that also lists what we don't check yet.
2) Type-to-pay on NEAR. Type "send 5 USDC to ana.near" and approve with Face ID. The server enforces per-payment and daily caps, and the keyboard can only pay people you already paid; a new recipient opens the app. The new phone-signed design keeps the Ed25519 key on the phone: the server only builds the transaction, checks the signature and broadcasts. Testnet by default; mainnet behind a switch.

Honest state: phone signing is done on the server and a terminal demo; the iOS app still uses a server-held testnet path. 202 server tests pass. Built 2026-11-12 to 11-14.
```

Before sending, count the characters again (`20–2000`). Check the README's "Limits and honest gaps" still matches the code.

## TODO for Boss man

1. Make https://github.com/varunlohade/pip public, with branch `ios-near` pushed (or merged to `main`), before 2026-11-14 23:59 UTC.
2. Add a LICENSE file (the rules ask for one; `server/package.json` already says MIT).
3. Record the video (`docs/DEMO-SCRIPT.md`) and publish the X post.
4. Fill in leadName, email, size, nearAddress, demoUrl, consent.
5. If you submit another project to this hackathon, name it in this README (rule Q-015).
