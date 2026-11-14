# Pip

Pip helps you get things done as you type. It sits in your keyboard like a quiet helper and offers the next useful step. Type "dinner with Ana friday 7pm" and one tap adds it to your calendar; "remind me tomorrow to call mom" becomes a reminder; Rewrite makes a message more polite, shorter or friendlier; Fix cleans up typos on the phone; "tip 18% on 64" shows the sum. Ask "explain compound interest" or "bar chart: rent 1200, food 400" and Pip draws it in the keyboard with Excalidraw (MIT), step by step, ready to send as an image or a link, with the phone's own voice if you tap the speaker. Pip also knows what short chat words like "btw" mean, with no network. The keys look and type like Apple's own. The app in `ios/` (SwiftUI, XcodeGen) walks you through making Pip your default keyboard; the small Hono server in `server/` (Node 24) handles device sign-in, the writing help, explanations, drawn scenes, shared drawing links and the few sentences the phone cannot read on its own. `visual/` builds the Excalidraw drawing page into `ios/Visual` (`npm install && npm run build`), trimmed to English with no CDN at runtime. Run `cd server && npm install && npm run setup && npm run dev`, then `cd ios && xcodegen` and open `Pip.xcodeproj`.

Email codes go out through Resend when `RESEND_API_KEY` and `MAIL_FROM` are set in `.env` (see `.env.example`). Without the key, the server sends nothing and only logs the kind of mail; `MAIL_DEV_PRINT=1` prints the code locally.

## Private AI on NEAR

Set `NEARAI_API_KEY` and the server sends writing help and explanations to NEAR AI Cloud (`https://cloud-api.near.ai/v1`) instead of OpenRouter. The default models are `Qwen/Qwen3.6-35B-A3B-FP8` (first) and `z-ai/glm-5.3-flash` (backup). Both run on NEAR's own GPUs inside a TEE (Intel TDX with NVIDIA GPUs), so neither NEAR nor the model host can read the text. `NEARAI_MODEL_PRIMARY` and `NEARAI_MODEL_FALLBACK` change them; the server refuses Claude and GPT ids. If NEAR fails, or the key is missing, the old OpenRouter path answers (`OPENROUTER_API_KEY`), and the reply says so.

Each reply from `/v1/write/*` and `/v1/explain*` carries `private`, `attested` and `model`. `private` is true only when every model that saw the text ran in a TEE. Tone check uses jev, which runs outside a TEE, so it reads `private: false`. `attested` is true only when the server checked that model's attestation in the last 10 minutes and every check passed. Replies never wait for a check; a cold model reads `attested: false` until its check finishes.

How the server checks (`server/src/nearai.ts`, Node crypto only):

1. It makes a fresh 32-byte nonce and calls `GET /v1/attestation/report?model=…&provider=near&signing_algo=ecdsa&nonce=…` with `x-no-aliasing: true`.
2. For the gateway report and each model report, it verifies the Intel TDX quote: the quote signature, the QE report, and the PCK certificate chain up to Intel's root CA (pinned by fingerprint).
3. From the quote it reads the report data and requires the signing address plus our nonce. It requires the debug bit off, MRCONFIGID equal to the hash of `app_compose`, and RTMR3 equal to the replayed event log.
4. After each reply it fetches `GET /v1/signature/<chat id>` and requires an EIP-191 signature, from the attested model key, over the SHA-256 of the exact request and response bytes.

`GET /v1/ai/attestation` (signed-in) returns all of this for the proof screen: each model's result, the last reply signature, the steps above, and what is not checked yet. Not checked yet: Intel TCB status and revocation lists, NVIDIA GPU evidence, and an allowlist of known good builds. Pip's server still sees your text before it reaches the TEE, so this is private from NEAR and the model host, not from Pip. To check a reply yourself, paste its chat id into https://cloud.near.ai/verify.
