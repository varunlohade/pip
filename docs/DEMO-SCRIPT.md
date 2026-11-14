# Demo video: shot list (60–90 s)

Record on the iOS simulator (or a phone) in Messages, with the Pip keyboard on. Use `npm run dev` with `NEARAI_API_KEY` and a testnet funder, so the AI and the payment are real. Keep it quiet: no music needed, short captions on screen.

| # | Time | Show | On-screen caption |
| --- | --- | --- | --- |
| 1 | 0–5 s | Messages chat. Pip keyboard up. | "Pip: a keyboard that gets things done, in any app." |
| 2 | 5–20 s | Type "coffee with Ana at 3:30pm". The calendar panel opens. It shows "busy: Dentist" and offers 2:30 PM. Tap 2:30 PM, then Add. Pip adds "works for me" to the message. | "It checks your calendar before you say yes." |
| 3 | 20–35 s | Type a blunt message, e.g. "send me the report now". Tap Rewrite. Versions stream in. Point at the green "Private AI" mark. Tap one to insert it. | "Rewrites run on NEAR AI Cloud, inside a TEE." |
| 4 | 35–42 s | Open the Pip app > Private AI proof screen. Scroll past "Models we checked" and "What we don't check yet". | "We check NEAR's hardware proof. We also list what we don't check yet." |
| 5 | 42–60 s | Back in Messages. Type "send 0.01 NEAR to ana.testnet" (a friend you paid before). The chip says "Approve". Tap it. Face ID. Pip types "Sent ✓" and the explorer link. | "Type to pay. Your daily limit, people you already paid." |
| 6 | 60–70 s | Type "send 0.01 NEAR to bob.testnet" (new recipient). Pip opens the app card instead. | "A new person always opens the app." |
| 7 | 70–80 s | Tap the explorer link. Show the tx on testnet.nearblocks.io. | "Real NEAR testnet transaction." |
| 8 | 80–90 s | Pip home screen with the repo URL. | "Built at NEAR HACKATHON. Code: github.com/varunlohade/pip" |

Notes before recording:

- Shot 5 uses the app's current path, which needs `PAY_LEGACY_CUSTODY=1` on the server. Do not call it "phone-held keys" on screen until the app signs on the phone.
- Do not show the funder account, `.env`, or any key on screen.
- Use a fake contact name and number in Messages.

# Draft X post

Boss man publishes it himself. Attach the video.

> Typing "send 5 USDC to ana" should be as easy as typing "see you at 5".
>
> Pip is an iPhone keyboard that does the next step for you, in any app: it checks your calendar, rewrites messages, and sends money.
>
> Built at NEAR HACKATHON:
> • Rewrites run in a TEE on NEAR AI Cloud. Pip checks the attestation and shows what it does not check yet.
> • Type-to-pay on NEAR, with daily limits and a known-recipient rule. Face ID to approve.
>
> Code: https://github.com/varunlohade/pip
> What would you want your keyboard to do next?
>
> @NEARProtocol #NEARHackathon @NearBuilders

Length check: keep it under 280 characters if Boss man has no X Premium. Short version:

> Pip: an iPhone keyboard that checks your calendar, rewrites in a NEAR AI TEE, and sends money on NEAR when you type "send 5 USDC to ana". Built at NEAR HACKATHON. https://github.com/varunlohade/pip @NEARProtocol #NEARHackathon
