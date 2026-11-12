# One-tap Send for drawings

Send used to copy the image, so the owner had to paste it, then send. A keyboard cannot attach an image (`textDocumentProxy` takes text only). Now one tap on Send types a caption and a short link, such as `log function, explained: https://…/d/<id>`. The chat shows the link as the picture.

Every path is in this repo (`/Users/varun/pip-keyboard`). Port it to Muninn in the same order.

## How it works

1. The drawing finishes. The keyboard exports the PNG and makes the JPEG preview on the phone. Nothing leaves the phone.
2. The owner taps **Send**. The keyboard exports the PNG again. If the bytes differ (the owner drew with the pen), it makes a new preview. Then it uploads the PNG and the preview, and the note says "Sending…" (a 55 KB preview takes well under a second).
3. At the same moment, the PNG goes to the pasteboard as a fallback.
4. The upload ends. The caption and link replace the typed request: "explain log function" becomes "log function, explained: <link>". Text typed before the request stays. If the request is no longer the last sentence, the link goes after the text. The note says "Link added. Tap send.", with a quieter "Image also copied" under it.
5. After 5 s, or on an error, the old hint shows ("Copied. Tap the message box and Paste, then send."). A late link is dropped. The next Send tries again.
6. **Send as image** moved into a small `…` menu next to Send. It only copies the PNG, as before.

With no Full Access, nothing is made or sent.

## Server

| Path | Change |
|---|---|
| `server/src/image.ts` | New. `isPng`, `pngSize` (IHDR) and `jpegSize` (SOF marker). No library. |
| `server/src/db.ts` | `shared_images` gets `preview BLOB, preview_w, preview_h, title`. Older databases get them through `ALTER TABLE` on open. `addSharedImage` takes one object. `sharedImage` returns the drawing, `'gone'` or `undefined`. `purgeSharedImages(at, keepGoneMs)` empties expired images but keeps the row, then deletes it after `keepGoneMs`. |
| `server/src/config.ts` | `sharedImage.keepGoneMs` (1 year), `sharedImage.preview` (`maxBytes` 300 KB, `minWidth` 600, `maxSide` 4096) and `maxTitleChars` (80). |
| `server/src/app.ts` | The routes below, `sharePage()`, `gonePage` and `esc()`. Images under `/d/` get `Cross-Origin-Resource-Policy: cross-origin`; the rest keeps `same-origin`. The `/v1/drawings` body limit is now PNG + preview + 16 KB. |
| `server/test/share.test.ts` | Tests for the OG tags, image types and sizes, refused previews, 410 after expiry, no listing, and the old-database upgrade. |

### Routes

| Route | Answer |
|---|---|
| `POST /v1/drawings` | `multipart/form-data` with `image` (PNG, at most 1 MB), `preview` (JPEG, at most 300 KB, 600 to 4096 px wide) and optional `title` (cleaned, cut to 80 characters). A bare `image/png` body from older builds still works, with no preview. Returns `{ url: <base>/d/<id>, image_url: <base>/d/<id>.png, expires_at }`. |
| `GET /d/<id>` | `text/html`: `og:type`, `og:site_name`, `og:title`, `og:description` ("Made with Pip"), `og:url`, `og:image` (the JPEG), `og:image:type/width/height/alt`, `twitter:card=summary_large_image`, `twitter:title/description/image`. The page shows the PNG full width, then "Made with Pip". It has no script. CSP: `default-src 'none'; img-src 'self'; style-src 'unsafe-inline'`. `Cache-Control: public, max-age=min(3600, seconds left)`. |
| `GET /d/<id>.jpg` | `image/jpeg`, the preview. 404 when the upload had none. |
| `GET /d/<id>.png` | `image/png`, the full drawing. |

Every `/d/` answer has `X-Robots-Tag: noindex, nofollow`. Images use `max-age=min(86400, seconds left)`, so no cache serves a drawing past its 30 days. After expiry, all three answer **410** with no image for a year, then 404. Ids stay 128 random bits, and no route lists them. With no preview, `og:image` falls back to the PNG.

## iOS

| Path | Change |
|---|---|
| `ios/Shared/LinkPreview.swift` | New. `LinkPreview.jpeg(png)`: flattens on white, 600 to 1200 px wide, JPEG quality 0.8 down to 0.35, then smaller, until it is at most 300 KB. (`SharePreview` clashes with SwiftUI.) |
| `ios/Shared/API.swift` | `shareDrawing(_ png:, preview:, title:)` sends multipart, or the bare PNG when `preview` is nil. |
| `ios/Shared/KeyboardDeps.swift` | The `KeyboardAPI.shareDrawing` signature. |
| `ios/Shared/KeyboardModel.swift` | Stored `sharePrepared: (png, preview)?` and `shareAttempt: UUID?`. |
| `ios/Shared/KeyboardModel+Explain.swift` | `VisualState.hint`; `Send.prepare`. `visualDone()` calls `prepareShare()`. New: `finishShare` (ends only the current attempt), `insertShareLink` (deletes the request with `deleteBackward`, then types the caption and link), `requestSubject`, `shareCaption`, and the `linkAdded`, `imageAlsoCopied`, `sendingNote` and `shareWait` constants. Rewritten: `sendVisual` and `visualExported`. `visualFailed` stays quiet for the export made ahead and clears `sending`. `openVisual` resets both share fields. |
| `ios/Shared/VisualPanel.swift` | Buttons: Send (`visual.send`, one tap), `…` (`visual.more`) and Insert. The menu holds Send as image (`visual.send.image`) and close. The note pill shows `hint` as a smaller second line (`visual.hint`). |
| `ios/App/IntroView.swift` | The stub API's new signature. |
| `ios/Tests/Fakes.swift` | `FakeAPI.shareDrawing` records png, preview and title. It has `shareFails`, `holdShares` and `releaseShares()`. |
| `ios/Tests/ExplainTests.swift` | Nothing uploads before Send, one-tap send, Sending then link, request replaced, earlier text kept, 5 s fallback with a late link dropped, failed upload tried again, a pen edit gets a new preview, no Full Access, the preview size. `FakePage` moved to file scope. |
| `ios/UITests/ExplainShots.swift` | `test2Explain` drives Send, the menu and Send as image in Messages. `openField` starts a chat on a new simulator. |

The 5 s wait uses two tasks, not a task group: awaiting `Task.value` cannot be cancelled, so a group would wait for the whole upload.

## Before launch

- Set `PUBLIC_URL` to the public https address. `og:image` must be absolute and public, or chats show no picture.
- After deploy, send a link in iMessage, WhatsApp, Telegram and Slack, and check the picture shows. Local checks cannot test this.
