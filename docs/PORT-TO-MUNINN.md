# Port the explainer to Muninn

This covers the explainer: meanings, explanations, the drawing panel, charts, voice, and sending a drawing. Pip was built from Muninn's keyboard base (`57390ee`), so the same files exist in Muninn and the hooks below line up. Every path is in this repo (`/Users/varun/pip-keyboard`).

Leave out Pip's B2 restyle (`Theme.swift` palette, onboarding hero, Home). The feature needs only a few of those pieces; see "Styling".

## 1. Copy as is

| Path | What it is |
|---|---|
| `ios/Shared/Engine/Explain.swift` | Finds explain questions on the phone ("what does btw mean", "explain X", "eli5 X"). Pure code. Also has `ExplainDictionary`. |
| `ios/Shared/Resources/explain-dictionary.json` | 1,453 terms with a meaning and an example each, written for Pip. Add it to both the app and keyboard targets. |
| `ios/Shared/Engine/MathExpr.swift` | Safe expression parser for graphs. Recursive descent, no eval. |
| `ios/Shared/Engine/Charts.swift` | `Chart.detect` (graph, bar, pie and line requests), `ChartScene` (the scene builder) and `DrawScene` (scene JSON). |
| `ios/Shared/KeyboardModel+Explain.swift` | All explainer state and actions: chip, card, visual panel, send, voice. It also defines `ExplainOffer`, `VisualState`, `ExplainPanel` and `VisualPage`. |
| `ios/Shared/ExplainCard.swift` | The card view shown in place of the keys. |
| `ios/Shared/VisualPanel.swift` | The drawing panel view, plus `VisualWebView`: a WKWebView hosting `ios/Visual`, a content rule that blocks http(s), and the `pip` message bridge. |
| `ios/Shared/Narration.swift` | `Speaker`, `NarrationSync` (keeps voice and drawing in step) and `SystemSpeaker` (AVSpeechSynthesizer, ambient audio). |
| `ios/Visual/` (whole folder) | The built Excalidraw page: `index.html`, `page.js`, fonts. Add it as a folder reference (`type: folder`, `buildPhase: resources`) to the app and the keyboard. |
| `visual/` (except `node_modules`) | The page source: `src/main.jsx`, `index.html`, `vite.config.js`, `copy-fonts.mjs`, `package.json`, `package-lock.json`. Run `npm install && npm run build`; the output goes to `ios/Visual`. |
| `ios/Tests/ExplainTests.swift`, `ios/Tests/ChartTests.swift`, `ios/Tests/NarrationTests.swift` | Unit tests. |
| `ios/UITests/ExplainShots.swift` | Optional UI test that drives a Messages chat. |
| `server/src/explain.ts` | Explanation and scene schemas, clamping, axes and plot sampling, prompts. |
| `server/test/explain.test.ts`, `server/test/share.test.ts`, `server/test/fixtures/log-explain.json`, `server/test/fixtures/log-scene.json` | Server tests and fixtures. |

## 2. Merge into existing Muninn files (hooks)

### iOS

- **`ios/Shared/KeyboardModel.swift`**
  - Add these stored properties: `explainOffer`, `explainPanel`, `explainTask`, `visualTask`, `explainPending`, `explainCache`, `weak var visualPage: VisualPage?` and `narration`.
  - Make `deps` and `typed` internal, not private. The extension file needs them.
  - In `textChanged()`:
    - When not paired, call `updateExplain(typed)` before the `guard paired` line (dictionary meanings work offline).
    - Then `let explaining = updateExplain(text)` after `let text = typed`.
    - Send `/v1/suggest` only `if !explaining`.
  - In `keyboardDisappeared()`, call `closeExplain()`.
  - In `barItems`, pass `explain: explainItem` to `BarItems.State`.
  - In `perform(_:)`, add `case .explain: openExplainCard()`.
  - Smart chips feed Home's "From your chats":
    - In `detectSmart`'s task, after `self.smart = shown`, call `recordCaught(shown)`.
    - In `tapSmart`, call `deps.store.removeCaught(...)`.
    - Add the `caught(_:seen:)` helper.
- **`ios/Shared/Engine/BarItems.swift`**
  - Add `Action.explain` and `State.explain: Item?`.
  - When there's no Full Access or no pairing, show the explain item in place of the info line.
  - In `.idle`, put the explain item first, and hide "copied" and "next" while it shows (the `aboutTyping` check).
- **`ios/Shared/KeyboardView.swift`**
  - Show `ExplainCardView` or `VisualPanelView` when `model.explainPanel` is set, padded like the notes panel.
  - Size the frame with `.frame(height: model.keyboardHeight)`.
  - In `SuggestionBar`:
    - Add the panel header (buddy plus the ice subject bubble, with the `explain.title` accessibility label).
    - Add `explainRow` (sky chip plus "Explain more").
    - Hide Fix, Rewrite and Notes while `explainOffer` or `explainPanel` is set.
- **`ios/Keyboard/KeyboardViewController.swift`**
  - Keep the height constraint.
  - Subscribe to `model.$explainPanel` and set the constant to `Theme.SystemKeyboard.visualHeight` (470) for `.visual`, otherwise to `.height`.
  - `@Published` sends the new value before the property changes, so use the sink's value, not `model.keyboardHeight`.
- **`ios/Shared/KeyboardDeps.swift`**
  - Add to `KeyboardAPI`: `explain(_:)`, `explainVisual(_:)` and `shareDrawing(_:)`.
  - Add to `KeyboardStore`: `saveDrawing(_:title:scene:)`, `recordLearned`, `recordCaught` and `removeCaught`.
  - Add `setPNG(_:)` to `Pasteboard` (UIPasteboard sets `UTType.png`).
  - Add `speaker` to `KeyboardDeps`.
- **`ios/Shared/API.swift`**
  - Add `ExplainResponse`.
  - Add `explain(_:)` (POST `/v1/explain`) and `explainVisual(_:)` (POST `/v1/explain/visual`, which returns raw scene Data).
  - Add `shareDrawing(_:)` (POST `/v1/drawings` with `image/png`).
- **`ios/Shared/SharedStore.swift`**
  - Add `drawings`, `drawingURL`, `drawingSceneURL` and `saveDrawing(_:title:scene:)` (keeps 30, newest first).
  - Add `learned` (kept 30 days) and `caught` (kept 7 days).
- **`ios/Shared/DayData.swift`**: add the `Drawing`, `Learned` and `Caught` models.
- **`ios/Shared/Theme.swift`**: add `SystemKeyboard.visualHeight = 470`.
- **`ios/App/IntroView.swift`**: if Muninn's intro has `DemoAPI`, `DemoStore` or `DemoPasteboard`, add the new protocol methods there as no-ops.
- **`ios/Tests/Fakes.swift`**: `FakeAPI` (explain, visual, share replies), `FakeStore` (drawings, learned, caught), `FakePasteboard.setPNG`, `FakeSpeaker`, and the `speaker:` parameter in `KeyboardDeps.fake`.
- **App side (optional, as on Pip's Home)**:
  - `ios/App/DrawingsSection.swift` lists saved drawings.
  - `ReplaySheet`, `ReplayController` and `ReplayWebView` in `ios/App/AskBar.swift` replay a drawing with "Play with voice".
  - `AskBar` itself is the Home "Ask Pip" bar; take it only if Muninn wants that.
- **`ios/project.yml`**: add the `Visual` folder reference to both targets, then run `xcodegen`.

### Server (Hono)

- **`server/src/ai.ts`**: add `explain(text)` and `visual(topic)` to the `Ai` type. `once()` makes one call to the primary model and falls back only if it fails; it parses with `ExplanationSchema` / `SceneSchema`. Explain timeout is `config.llm.explainTimeoutMs`.
- **`server/src/config.ts`**:
  - `maxExplainChars: 200`
  - `sharedImage: { maxBytes: 1 MB, ttlMs: 30 days }`
  - `publicUrl` (env `PUBLIC_URL`)
  - `llm.explainTimeoutMs: 15000`
  - rate limits: `explain` (10/min), `explainDaily` (100/day), `shareUpload` (20/hour), `shareView` (120/min per IP)
- **`server/src/db.ts`**: add the `shared_images` table plus its index, and `addSharedImage`, `sharedImage(id, at)` and `purgeSharedImages(at)`.
- **`server/src/app.ts`**:
  - The `/v1/*` 16 KB body limit skips `/v1/drawings`, which gets its own 1 MB limit.
  - One limiter pattern, `app.use('/v1/explain/*', ...)`, covers both explain routes (Hono's `/*` also matches `/v1/explain`).
  - Routes are listed below.
- **`server/test/helpers.ts`**: the fake `Ai` gets `explain` and `visual`, which run the real schemas over raw model JSON (defaults are the log fixtures).
- **`server/scripts/fake-server.ts`**:
  - `/_next` accepts `explain` and `visual`.
  - The proxy passes request bodies as bytes. Text corrupts PNG uploads.
- **`server/SECURITY.md`**: copy the "Shared drawings" section.

## 3. Server routes

| Route | Auth | Body | Answer |
|---|---|---|---|
| `POST /v1/explain` | device token | `{text}` (cleaned, max 200 chars) | `{short, body (up to 4 lines joined by \n), visual_ok}`. 502 with no detail on model failure. |
| `POST /v1/explain/visual` | device token | `{topic}` | Scene `{title, canvas {w: 800, h: 500}, steps: [{say, shapes}]}`. Shapes are `text`, `rect`, `ellipse`, `arrow` and `line`. Axes and plots are expanded and sampled on the server. Clamped to 4 steps, 60 shapes and board coordinates. |
| `POST /v1/drawings` | device token | raw `image/png` (magic bytes checked, 1 MB max) | `{url, expires_at}`. The url is `/d/<22 base64url chars>.png` (128 random bits) and lasts 30 days. |
| `GET /d/:id.png` | none | – | The PNG with `nosniff` and `default-src 'none'`. Unknown and expired ids both return 404. No route lists ids. |

The phone also sends `polygon` shapes (pie wedges) from `ChartScene`. Only the page draws them; the server never makes them.

## 4. The page contract (`ios/Visual/index.html`)

- **Native to page (`window.pip`):**
  - `play(sceneJSON)`, `replay()`
  - `tool('draw' | 'eraser' | 'hand')`
  - `undo()`, `redo()`
  - `voice(on)`, `next()`
  - `export()`
- **Page to native (`webkit.messageHandlers.pip`):**
  - `{type: 'ready'}`
  - `{type: 'step', n, m, say}`
  - `{type: 'stepDrawn', n}`
  - `{type: 'done', m}`
  - `{type: 'png', data: base64}`
  - `{type: 'error', message}`
- With voice on, the page waits after each step until `pip.next()`. `NarrationSync` calls it when the line is spoken, or after 8 s at most.
- The page loads from `file://` as one classic script. It never touches the network: the content rule blocks http(s), and fonts load from `ios/Visual/fonts`.

## 5. Styling

`ExplainCard.swift`, `VisualPanel.swift` and the bar row use these pieces from `ios/Shared/Brand.swift`: `Buddy`, `SkyPill`, `FrostPill`, `FrostFill`, `SkyFill`, `IcePill`, `ringCard()` and `StepDashes`. They also use these `Theme.Color` tokens: `sky`, `skyDeep`, `skyOnText`, `ice`, `navy`, `text1`, `text2`, `text3`, `ring`.

You have two choices:
- Copy `Brand.swift` and those tokens.
- Swap those calls for Muninn's own button and card styles. The views keep layout and style apart, so this is a short edit.

## 6. Checks after the port

- `cd server && npm test && npx tsc --noEmit`. Pip has 66 server tests.
- iOS unit tests: `ExplainDetectTests`, `ExplainDictionaryTests`, `ExplainModelTests`, `MathExprTests`, `ChartDetectTests`, `ChartSceneTests`, `NarrationSyncTests`, `VoiceModelTests`.
- Run UI tests with `xcodebuild test`, or install the app with `xcrun simctl install` first. `test-without-building` may leave an old app, and an old keyboard extension, on the simulator.
- Never play voice on the owner's devices or the simulator while testing. Use `FakeSpeaker`.
