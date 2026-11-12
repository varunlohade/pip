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
    func refine(_ text: String, tone: String) async throws -> WriteResponse { calls.append("refine"); return writeReply }
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
    func releaseShares() { let h = heldShares; heldShares = []; h.forEach { $0.resume() } }
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
}

final class FakePasteboard: Pasteboard {
    var string: String?
    var changeCount = 0
    var hasStrings: Bool { string != nil }

    func copy(_ s: String) { string = s; changeCount += 1 }
    private(set) var png: Data?
    func setPNG(_ png: Data) { self.png = png; changeCount += 1 }
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
                     haptics: HapticSpy = HapticSpy()) -> KeyboardDeps {
        KeyboardDeps(api: { api }, store: store, pasteboard: pasteboard,
                     now: { MainActor.assumeIsolated { clock.now } },
                     sleep: { d in try await clock.sleep(d) }, writer: writer, speaker: { speaker },
                     wipeProcess: { store.processWipes += 1 }, haptics: { haptics })
    }
}

extension Duration {
    var seconds: TimeInterval { Double(components.seconds) + Double(components.attoseconds) * 1e-18 }
}
