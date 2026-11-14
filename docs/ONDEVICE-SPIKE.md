# On-device model spike (Apple Foundation Models)

Branch `ondevice`, 2026-11-14. Spike only: the probe is DEBUG-only and nothing here is product code.

## Answer

**Yes. The Pip keyboard extension can call `SystemLanguageModel` in the simulator, with and without Full Access.**
The app can call it too. Both report `available` and a 4096-token context.

Evidence: `docs/ondevice-spike/run2-keyboard-no-full-access.log` and `run3-keyboard-full-access.log`.
Each has 32 `PROBE` lines from the `PipKeyboard` process (availability, 30 items, memory).

### Simulator caveat

The iOS 26.4 simulator runs the model on the host Mac (Apple M4 Max, macOS 26.4.1, Apple Intelligence on).
So "available" here proves that the API and the keyboard sandbox allow the call. It does not prove an iPhone allows it.
The latency numbers are Mac speed, not iPhone speed. Quality should match the iPhone model (both are the 26.4 model), but I did not check that.

A real iPhone needs all of these, or `availability` returns the reason:
- an Apple Intelligence device: iPhone 15 Pro / Pro Max, or any iPhone 16 or 17 model (`deviceNotEligible` otherwise);
- iOS 26, Apple Intelligence turned on in Settings (`appleIntelligenceNotEnabled`);
- the model downloaded (`modelNotReady`; it can take a while after turning it on);
- a supported region and language (Apple Intelligence is not offered in every region).

Not tested on a device (no device installs in this spike).

## What Apple's docs say

- Context: 4096 tokens per session, input plus output (TN3193). Measured `contextSize` = 4096.
- Guided generation: `@Generable` types; the schema costs tokens. Tool calling: `Tool` protocol; keep to 3-5 tools.
- Memory: an Apple DTS engineer says the system model is not loaded into the app or extension, so it does not count against the extension's memory limit. He also says "some extensions don't allow XPC due to privacy reason, and hence can't use a model via the Foundation Models framework". He does not name which ones. ([forum thread 833575](https://developer.apple.com/forums/thread/833575))
- Rate limits: on battery, a process in the background gets rate-limited. Apple suggests `respond` over streaming there. Whether a visible keyboard counts as foreground is not documented. ([forum thread 789788](https://developer.apple.com/forums/thread/789788))
- Model versions change with the OS (26.0-26.3, 26.4, 27.0), so output quality can change under us.

## Results

30 items written for this spike (no personal data), in `ios/Shared/OnDeviceProbe.swift`.
Same instructions as `server/src/ai.ts` (WRITER + fix / refine text), greedy sampling, a new session per item.
Latency is from the keyboard run with Full Access (run 3). The app numbers were within 25 ms of these.

| Task (10 items each) | On-device pass (auto rule) | On-device pass (my read) | TTFT median | Total median | Total max | Server pass | Server latency |
|---|---|---|---|---|---|---|---|
| Fix | 3/10 | 3/10 | 395 ms | 481 ms | 653 ms | not measured | not measured |
| Rewrite (polite / shorter / professional) | 5/10 | 2/10 | 408 ms | 653 ms | 1136 ms | not measured | not measured |
| Intent (plan / reminder / note / question / none, `@Generable` enum) | 4/10 | 4/10 | 254 ms | 314 ms | 328 ms | not measured | not measured |

**Server column: not measured.** No API key exists: there is no `~/pip-keyboard/.env` (the dev script reads `../.env`) and no `server/.env`.
I did not use `npm run fake`, because its answers are canned.

Outputs were identical in the app and the keyboard, and with or without Full Access (greedy decoding).
The first call after a cold start (run 1, app) took 3792 ms to first token; later calls took about 400 ms.

### How items pass

- Fix: the output must match the reference after lowercasing and dropping spaces and punctuation other than `'` and `$`.
- Rewrite (auto rule): no "Sure, here is" preamble, keeps the listed facts, then polite has please/could you/would you/thank; shorter is at most 75% of the words; professional has no slang (hey, yo, tmrw, asap).
- Rewrite (my read): the auto rule, and the text is still the sender's message. rw02, rw08 and rw10 pass the auto rule but answer the message instead of rewriting it.
- Intent: exact label.

Run `python3 -I docs/ondevice-spike/grade.py docs/ondevice-spike/run3-keyboard-full-access.log` to see every output.

### What went wrong

- The model often answers the text instead of editing it: "thanks for you help" became "You're welcome! I'm glad I could help...". 7 of 20 Fix/Rewrite items did this (fix02, fix04, fix07, rw02, rw05, rw08, rw10).
- It adds preambles ("Sure, here is the rewritten text:") in 3 items (fix08, rw01, rw03), even when told to reply with the text only.
- "Shorter" returned the input unchanged in 2 of 3 items.
- Fix changed meaning ("i will be their" became "You will be there") and added facts ("7" became "7 PM").
- Intent: both questions came back as `note`, "haha that was so funny" as `note`, a pickup task and a parking spot as `plan`, and a Tuesday meeting as `none`.

## Memory (keyboard footprint, `phys_footprint`)

| Run | Before first call | After first call | Peak | After 30 calls |
|---|---|---|---|---|
| Keyboard, no Full Access | 36.1 MB | 55.6 MB | 57.2 MB | 56.8 MB |
| Keyboard, Full Access | 36.3 MB | 41.0 MB | 58.8 MB | 58.5 MB |
| App, under UI test (run 3) | 28.5 MB | 46.2 MB | 47.5 MB | 47.3 MB |
| App, first cold launch | 25.7 MB | 23.1 MB | 25.7 MB | 25.2 MB |

The keyboard grows by about 20-22 MB during the first few calls, then stays flat.
The weights are not in our process, so this is likely the framework's client side. I did not find out what it is.
The cold-launch app run did not show the jump, and I cannot explain that.
Simulator footprint is not device footprint. iOS does not publish the keyboard memory limit; reports range from about 48 to 70 MB.
So 57-59 MB in a keyboard is a real risk.

## Recommendation

Do not move Fix or Rewrite on-device now. With Pip's current prompt, the on-device model passes 3/10 Fix and 2/10 Rewrite by my read, and it often replies to the message, which is the worst failure for a keyboard.
The speed is good (under 0.7 s median on the Mac), and the keyboard sandbox allows the call, so it can serve later as an offline fallback once the quality improves.

Next steps, in order:
1. Measure the server on the same 30 items once a dev key is in `.env`, so the comparison is real.
2. Try a prompt built for the small model: `@Generable struct { text }` output, the input in quotes or marked "Text to edit:", one example. Re-run the same set.
3. On a real Apple Intelligence iPhone: availability, TTFT, and keyboard footprint against the jetsam limit.

## Open risks

- Device behaviour is unproven: availability, speed, the 20 MB jump, and whether a keyboard counts as background for rate limits.
- Apple says some extensions cannot use XPC for the model. Keyboards worked in the simulator, but the simulator may not apply device sandbox rules.
- The model changes with OS updates, so a passing prompt can regress.
- 30 items is a small set; one item is 10 points.

## Files

- `ios/Shared/OnDeviceProbe.swift`: the probe and the eval items (DEBUG only).
- `ios/App/PipApp.swift`: `-ondeviceProbe YES` opens a probe screen (DEBUG only).
- `ios/Keyboard/KeyboardViewController.swift`: runs the probe when the field holds `ondevice-probe` (DEBUG only).
- `ios/UITests/OnDeviceProbeRun.swift`: turns the keyboard on in Settings and drives both runs.
- `docs/ondevice-spike/grade.py` and `run*.log`: the scorer and the raw probe lines.
