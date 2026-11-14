import UIKit
@testable import Pip

/// A text field the model types into. `text` is the whole field; the cursor is at the end.
@MainActor
final class FakeHost: TextHost {
    var text = ""
    var hasFullAccess = true
    var needsGlobeKey = false
    var returnKeyType: UIReturnKeyType = .default
    var autocapitalization: UITextAutocapitalizationType = .sentences
    var enablesReturnKeyAutomatically = false
    var keyboardType: UIKeyboardType = .default
    var textContentType: UITextContentType?
    var autocorrection: UITextAutocorrectionType = .default
    /// The text after the cursor. The trackpad moves characters between `text` and `after`.
    var after = ""
    private(set) var cursorMoves: [Int] = []

    var contextBeforeInput: String? { text }
    var contextAfterInput: String? { after }
    func insert(_ s: String) { text += s }
    func deleteBackward() { if !text.isEmpty { text.removeLast() } }
    func adjustCursor(by offset: Int) {
        cursorMoves.append(offset)
        if offset < 0 {
            let u = Array(text.utf16), n = min(-offset, u.count)
            after = String(decoding: u.suffix(n), as: UTF16.self) + after
            text = String(decoding: u.dropLast(n), as: UTF16.self)
        } else {
            let u = Array(after.utf16), n = min(offset, u.count)
            text += String(decoding: u.prefix(n), as: UTF16.self)
            after = String(decoding: u.dropFirst(n), as: UTF16.self)
        }
    }
    func nextKeyboard() {}
    func playClick() {}
    /// Links the keyboard tried to open, and whether the host lets it.
    private(set) var opened: [URL] = []
    var canOpen = false
    func open(_ url: URL) -> Bool { opened.append(url); return canOpen }
}

/// Answers with canned replies and records every call. Main-actor bound, so the model's tasks and the test never race on it.
@MainActor
final class FakeAPI: KeyboardAPI {
    var suggestReply = SuggestResponse(chips: [], intent: "none", timings: nil)
    var writeReply = WriteResponse(text: "", changed: nil)
    var toneReply = ToneResponse(tone: "ok", calm: nil)
    var explainReply = ExplainResponse(short: "A log is the power you need.", body: "log10(100) = 2", visual_ok: true)
    var visualReply = Data(#"{"title":"Logs","canvas":{"w":800,"h":500},"steps":[]}"#.utf8)
    private(set) var explained: [String] = []

    private(set) var calls: [String] = []
    private(set) var suggested: [(text: String, context: String?)] = []
    /// When set, suggest() runs this before it answers, so a test can change the text mid-request.
    var duringSuggest: (() -> Void)?

    nonisolated init() {}

    func suggest(_ text: String, context: String?) async throws -> SuggestResponse {
        calls.append("suggest"); suggested.append((text, context))
        duringSuggest?()
        return suggestReply
    }

    func fix(_ text: String) async throws -> WriteResponse { calls.append("fix"); return writeReply }
    /// Each rewrite call, and the stream the test feeds with send(_:) and end().
    private(set) var rewrites: [(text: String, tones: [String])] = []
    private var rewriteStreams: [AsyncThrowingStream<RewriteLine, Error>.Continuation] = []
    func rewrite(_ text: String, tones: [String]) -> AsyncThrowingStream<RewriteLine, Error> {
        calls.append("rewrite"); rewrites.append((text, tones))
        let (stream, cont) = AsyncThrowingStream<RewriteLine, Error>.makeStream()
        rewriteStreams.append(cont)
        return stream
    }
    /// A version arrives on the latest rewrite call.
    func send(_ tone: RefineTone, _ text: String) { rewriteStreams.last?.yield(RewriteLine(tone: tone.rawValue, text: text)) }
    func endRewrite(throwing error: Error? = nil) {
        if let error { rewriteStreams.last?.finish(throwing: error) } else { rewriteStreams.last?.finish() }
    }
    func toneCheck(draft: String, client: String?) async throws -> ToneResponse { calls.append("tone"); return toneReply }
    func explain(_ text: String) async throws -> ExplainResponse { calls.append("explain"); explained.append(text); return explainReply }
    func explainVisual(_ topic: String) async throws -> Data { calls.append("visual"); explained.append(topic); return visualReply }
    var shareReply = "http://localhost/d/AAAAAAAAAAAAAAAAAAAAAA"
    var shareFails = false
    /// When true, each upload waits until releaseShares(), so a test can tap Send while it runs.
    var holdShares = false
    private(set) var shared: [(png: Data, preview: Data?, title: String)] = []
    private var heldShares: [CheckedContinuation<Void, Never>] = []
    func shareDrawing(_ png: Data, preview: Data?, title: String) async throws -> String {
        calls.append("share"); shared.append((png, preview, title))
        if holdShares { await withCheckedContinuation { heldShares.append($0) } }
        if shareFails { throw APIError.message("upload failed") }
        return shareReply
    }
    var ratesReply = Calc.Rates(base: "USD", date: "2026-11-12", fetched_at: Date(timeIntervalSince1970: 1_799_999_400), rates: ["USD": 1, "INR": 94.04, "EUR": 0.90245])
    var ratesFail = false
    func rates() async throws -> Calc.Rates {
        calls.append("rates")
        if ratesFail { throw APIError.message("no rates") }
        return ratesReply
    }
    func releaseShares() { let h = heldShares; heldShares = []; h.forEach { $0.resume() } }

    // Pay: the intent the server would make, and what the keyboard approve answers.
    var keyboardCheck: PayIntent.KeyboardCheck? = .init(ok: true, reason: nil, left: "20", paid_before: 2)
    var keyboardApproveError: Error?
    private(set) var proposed: [PayDraft] = []
    private(set) var keyboardApproved: [(id: String, key: String)] = []
    private(set) var rejected: [String] = []
    func createPayIntent(_ d: PayDraft) async throws -> PayIntent {
        calls.append("payIntent"); proposed.append(d)
        return PayIntent.fake(d, keyboard: keyboardCheck)
    }
    func keyboardApprovePay(_ i: PayIntent, keyboardKey: String) async throws -> PayIntent {
        calls.append("keyboardApprove"); keyboardApproved.append((i.id, keyboardKey))
        if let e = keyboardApproveError { throw e }
        return PayIntent.fake(PayDraft(amount: i.amount, token: i.token, recipient: i.recipient, trigger: ""), status: "sent")
    }
    func rejectPay(_ id: String) async throws -> PayIntent {
        calls.append("reject"); rejected.append(id)
        return PayIntent.fake(PayDraft(amount: "5", token: "USDC", recipient: "ana.testnet", trigger: ""), status: "rejected")
    }
}

extension PayIntent {
    static let fakeID = String(repeating: "ab", count: 16)
    static func fake(_ d: PayDraft, status: String = "pending", keyboard: KeyboardCheck? = nil) -> PayIntent {
        let hash = status == "sent" ? "7Hq2Xb9TfE3mNwq8RkLz5VdYc1pA6sGh1uJkP4" : nil
        return PayIntent(id: fakeID, amount: d.amount, token: d.token, recipient: d.recipient, status: status, network: "testnet",
                         tx_hash: hash, explorer_url: hash.map { "https://testnet.nearblocks.io/txns/\($0)" },
                         deep_link: "pip://approve/\(fakeID)", keyboard: keyboard)
    }
}

/// Face ID that answers what the test says, and counts the asks.
final class FakeAuth: Authenticator, @unchecked Sendable {
    var answer: AuthResult = .approved
    private(set) var asks = 0
    func confirm(_ reason: String) async -> AuthResult { asks += 1; return answer }
}

/// In-memory stand-in for the App Group files and the Keychain token. Paired by default.
final class FakeStore: KeyboardStore {
    var signedIn = true
    var accountEpoch: String?
    var keyboardSeenEpoch: String?
    /// How many times the keyboard wiped its own process caches.
    var processWipes = 0
    var keyboardLastSeen: Date?
    var lastPasteboardChange = 0
    var appointments: [Appointment] = []
    var notes: [Note] = []
    var actionShortcuts: [ActionShortcut] = ActionShortcut.defaults
    private(set) var drawings: [(png: Data, title: String, scene: Data?)] = []
    func saveDrawing(_ png: Data, title: String, scene: Data?) throws { drawings.append((png, title, scene)) }
    private(set) var learned: [Learned] = []
    func recordLearned(_ l: Learned) { learned.append(l) }
    private(set) var caught: [Caught] = []
    func recordCaught(_ c: Caught) { if !caught.contains(where: { $0.id == c.id }) { caught.append(c) } }
    func removeCaught(id: String) { caught.removeAll { $0.id == id } }
    var keyHaptics = true
    /// How many times something read the rates file.
    private(set) var ratesReads = 0
    private var rates: Calc.Rates?
    var currencyRates: Calc.Rates? {
        get { ratesReads += 1; return rates }
        set { rates = newValue }
    }
    var payPending: String?
    var paySent: PaySent?
    var payKeyboardKey: String? = "pkb_fake_keyboard_key_for_tests_only"
    var payFaceID = true
}

/// Records every key haptic instead of playing it.
@MainActor
final class HapticSpy: KeyHaptics {
    private(set) var taps: [HapticStrength] = []
    private(set) var prepared = 0
    nonisolated init() {}
    func prepare() { prepared += 1 }
    func tap(_ strength: HapticStrength) { taps.append(strength) }
}

/// The phone's calendar and reminders, in memory. `granted` is what the app was allowed.
final class FakeWriter: SmartWriter {
    struct Failure: Error {}
    var granted: Set<SmartChip.Place> = [.calendar, .reminders, .notes]
    var fails = false
    private(set) var events: [String: (title: String, start: Date, end: Date?)] = [:]
    private(set) var reminders: [String: (title: String, due: Date)] = [:]

    func access(_ place: SmartChip.Place, hasFullAccess: Bool) -> SmartAccess {
        guard hasFullAccess else { return .needsFullAccess }
        return granted.contains(place) ? .ready : .needsPermission
    }
    func addEvent(title: String, start: Date, end: Date?) throws -> String {
        if fails { throw Failure() }
        let id = "E\(events.count + 1)"; events[id] = (title, start, end); return id
    }
    func addReminder(title: String, due: Date) throws -> String {
        if fails { throw Failure() }
        let id = "R\(reminders.count + 1)"; reminders[id] = (title, due); return id
    }
    func removeEvent(_ id: String) throws { events[id] = nil }
    func removeReminder(_ id: String) throws { reminders[id] = nil }
    /// What the phone's calendar already holds. `canRead` false: write-only access, or none.
    var calendar: [Appointment] = []
    var canRead = true
    func events(from: Date, to: Date, hasFullAccess: Bool) -> [Appointment]? {
        guard hasFullAccess, canRead else { return nil }
        let added = events.compactMap { id, e in e.end.map { Appointment(start: e.start, end: $0, title: e.title, color: nil) } }
        return (calendar + added).filter { $0.start < to && $0.end > from }.sorted { $0.start < $1.start }
    }
}

final class FakePasteboard: Pasteboard {
    var string: String?
    var changeCount = 0
    var hasStrings: Bool { string != nil }

    func copy(_ s: String) { string = s; changeCount += 1 }
    private(set) var png: Data?
    func setPNG(_ png: Data) { self.png = png; changeCount += 1 }
    func setText(_ text: String) { copy(text) }
}

/// A clock the test moves by hand. sleep waits until advance() moves `now` past its deadline,
/// so a loop that sleeps does not spin and a debounce really waits.
/// Main-actor bound so tasks that sleep at the same time do not race on the waiters.
@MainActor
final class FakeClock {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    private(set) var sleeps: [Duration] = []
    private var waiters: [(id: UUID, until: Date, cont: CheckedContinuation<Void, Error>)] = []

    nonisolated init() {}

    /// Tasks asleep right now.
    var sleeping: Int { waiters.count }

    func advance(_ seconds: TimeInterval) {
        now += seconds
        let due = waiters.filter { $0.until <= now }
        waiters.removeAll { $0.until <= now }
        for w in due { w.cont.resume() }
    }

    /// `sleeps` records only the waits that began, not those of tasks already cancelled.
    func sleep(_ d: Duration) async throws {
        let id = UUID()
        let until = now + Double(d.components.seconds) + Double(d.components.attoseconds) * 1e-18
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { cont.resume(throwing: CancellationError()); return }
                sleeps.append(d)
                waiters.append((id, until, cont))
            }
        } onCancel: {
            Task { @MainActor in self.wake(id, throwing: CancellationError()) }
        }
    }

    private func wake(_ id: UUID, throwing error: Error) {
        guard let i = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: i).cont.resume(throwing: error)
    }
}

/// A voice that makes no sound: it records each line and finishes only when the test says so.
@MainActor
final class FakeSpeaker: Speaker {
    private(set) var said: [String] = []
    private(set) var stops = 0
    private var pending: (() -> Void)?
    nonisolated init() {}
    /// Like the real one, a new line ends the one before it (its completion runs first).
    func say(_ text: String, done: @escaping () -> Void) { let p = pending; pending = nil; p?(); said.append(text); pending = done }
    func stop() { stops += 1; let p = pending; pending = nil; p?() }
    /// The current line ends.
    func finish() { let p = pending; pending = nil; p?() }
}

@MainActor
extension KeyboardDeps {
    static func fake(api: FakeAPI, store: FakeStore = FakeStore(), pasteboard: FakePasteboard = FakePasteboard(),
                     clock: FakeClock = FakeClock(), writer: FakeWriter = FakeWriter(), speaker: FakeSpeaker = FakeSpeaker(),
                     haptics: HapticSpy = HapticSpy(), auth: FakeAuth = FakeAuth()) -> KeyboardDeps {
        KeyboardDeps(api: { api }, store: store, pasteboard: pasteboard,
                     now: { MainActor.assumeIsolated { clock.now } },
                     sleep: { d in try await clock.sleep(d) }, writer: writer, speaker: { speaker },
                     wipeProcess: { store.processWipes += 1 }, haptics: { haptics }, auth: { auth })
    }
}

extension Duration {
    var seconds: TimeInterval { Double(components.seconds) + Double(components.attoseconds) * 1e-18 }
}
