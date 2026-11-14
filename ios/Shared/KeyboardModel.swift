import Combine
import Foundation
import UIKit
import os

/// What the keyboard needs from its host. The extension maps it to textDocumentProxy.
/// The app's debug screen maps it to a plain string.
@MainActor
protocol TextHost: AnyObject {
    var contextBeforeInput: String? { get }
    var hasFullAccess: Bool { get }
    var needsGlobeKey: Bool { get }
    var returnKeyType: UIReturnKeyType { get }
    var autocapitalization: UITextAutocapitalizationType { get }
    var enablesReturnKeyAutomatically: Bool { get }
    /// The text after the cursor, for the space-bar trackpad and the empty-field check.
    var contextAfterInput: String? { get }
    var keyboardType: UIKeyboardType { get }
    var textContentType: UITextContentType? { get }
    /// .no turns autocorrect off.
    var autocorrection: UITextAutocorrectionType { get }
    func insert(_ text: String)
    func deleteBackward()
    /// Moves the cursor by this many UTF-16 units; negative is left.
    func adjustCursor(by offset: Int)
    func nextKeyboard()
    func playClick()
    /// Opens a link in another app. Keyboards have no API for it; false when it could not.
    func open(_ url: URL) -> Bool
}

extension TextHost {
    func open(_ url: URL) -> Bool { false }
    var contextAfterInput: String? { nil }
    var keyboardType: UIKeyboardType { .default }
    var textContentType: UITextContentType? { nil }
    var autocorrection: UITextAutocorrectionType { .default }
    func adjustCursor(by offset: Int) {}
}

enum ShiftState { case off, once, locked }

/// What the return key says, from the field's returnKeyType. Non-default types get the blue key, like iOS.
struct ReturnStyle: Equatable {
    let title: String?
    let accent: Bool

    init(_ type: UIReturnKeyType) {
        switch type {
        case .go: title = "go"
        case .google, .yahoo, .search: title = "search"
        case .join: title = "join"
        case .next: title = "next"
        case .route: title = "route"
        case .send: title = "send"
        case .done: title = "done"
        case .emergencyCall: title = "Emergency"
        case .continue: title = "continue"
        default: title = nil
        }
        accent = title != nil && type != .next && type != .continue
    }
}

enum BarState: Equatable {
    case idle
    case working(String)
    case done(String)
    case error(String)
}

/// The versions in the Rewrite list. The raw value is the server's name for each.
enum RefineTone: String, CaseIterable, Identifiable {
    case polite, shorter, professional, friendly, firmer, fix
    var id: String { rawValue }
    var title: String {
        switch self {
        case .polite: "More polite"
        case .shorter: "Shorter"
        case .professional: "More professional"
        case .friendly: "Friendlier"
        case .firmer: "Firmer"
        case .fix: "Fixed grammar"
        }
    }
}

/// One version in the Rewrite list. `stalled`: no answer in time; the row offers Retry.
struct RewriteRow: Equatable, Identifiable {
    enum Status: Equatable { case writing, ready(String), stalled }
    let tone: RefineTone
    var status: Status = .writing
    /// Counts the asks for this row, so an older call's stall timer leaves a retried row alone.
    var attempt = 0
    var id: String { tone.rawValue }
    var text: String? { if case .ready(let t) = status { t } else { nil } }
}

/// Every version of the paragraph before the cursor, filled in as each one arrives.
struct RewriteList: Equatable {
    /// What a tap replaces.
    let original: String
    /// What was sent, quoted at the top.
    let text: String
    var rows: [RewriteRow] = RefineTone.allCases.map { RewriteRow(tone: $0) }
    /// The version a hold copied.
    var copied: RefineTone?
    /// "Private AI · verified on NEAR" when every version so far came from an attested TEE.
    var privacy: PrivacyMark?

    mutating func set(_ tone: RefineTone, _ status: RewriteRow.Status) {
        if let i = rows.firstIndex(where: { $0.tone == tone }) { rows[i].status = status }
    }

    /// The rows of one ask that are still writing show Retry.
    mutating func stall(_ asked: [RefineTone: Int]) {
        for i in rows.indices where rows[i].status == .writing && asked[rows[i].tone] == rows[i].attempt { rows[i].status = .stalled }
    }
}

/// A rewrite the owner can look at before it replaces `original`, the text before the cursor.
struct WritePreview: Equatable {
    let kind: String
    let title: String
    let original: String
    let text: String
}

enum WritePanel: Equatable {
    case menu
    case versions(RewriteList)
    case preview(WritePreview)
    /// Nothing came back: one plain line and Retry.
    case failed(String)
}

/// The last replacement, kept for a few seconds so one tap puts the old text back.
struct WriteUndo: Equatable {
    let label: String
    let original: String
    let replacement: String
}

/// A smart chip one tap added, and what Undo removes.
struct SmartAdded: Equatable {
    enum Item: Equatable { case event(String), reminder(String), note(UUID) }
    let chip: SmartChip
    let label: String
    let item: Item
}

@MainActor
final class KeyboardModel: ObservableObject {
    @Published var bar: BarState = .idle
    @Published var copiedAvailable = false
    /// Today's appointments, as the main app last wrote them, for the ready chips. Only the calendar panel reads the calendar itself.
    @Published var appointments: [Appointment] = []
    @Published var notesOpen = false
    @Published var notes: [Note] = []
    @Published var writeOpen = false
    @Published var writePanel: WritePanel = .menu
    @Published var undo: WriteUndo?
    /// What Fix would change in the text before the cursor. Nil when it looks clean.
    @Published var fixPlan: FixPlan?
    var fixable: Bool { fixPlan != nil }
    /// A calm reply for an upset copied message, ready to preview.
    @Published var calmOffer: WritePreview?
    /// "fix", "refine" or "tone" after a rewrite went into the field, and the trigger of the last shortcut. The intro watches both.
    @Published var lastWrite: String?
    @Published var lastShortcut: String?
    @Published var layout: KeyLayout = .letters
    @Published var shift: ShiftState = .once
    @Published var isDark = false
    @Published var pressedKeys: Set<String> = []
    @Published var calloutKeyID: String?
    /// The accent popup over a held letter.
    @Published var accents: AccentPopup?
    /// Space is a trackpad: the finger moves the cursor and the key faces go blank.
    @Published var trackpad = false
    /// The word slots: as typed, what space puts in, the next best; or next-word guesses after a space.
    @Published var words = WordRow()
    /// What the field wants: letters, digits, an email or a link.
    @Published var field: FieldKind = .text
    /// False on an empty field that asks Return to wait for text.
    @Published var returnEnabled = true
    @Published var returnStyle = ReturnStyle(.default)
    @Published var hasFullAccess = false
    @Published var paired = false
    @Published var lastLatencyMs: Int?
    /// Events, reminders and notes read from the typed text on the phone.
    @Published var smart: [SmartChip] = [] { didSet { noteChipsShown() } }
    /// The line after a smart chip was added, kept for the Undo window.
    @Published var added: SmartAdded?
    /// Nothing is typed, so the bar shows ready chips.
    @Published var fieldEmpty = true
    /// A meaning or an answer for what the last sentence asks ("what does btw mean"). See KeyboardModel+Explain.
    @Published var explainOffer: ExplainOffer? { didSet { noteChipsShown() } }
    /// A topic the bar offers to draw ("explain compound interest", or what the router called "understand"). See KeyboardModel+Explain.
    @Published var drawTopic: Explain.Ask? { didSet { noteChipsShown() } }
    /// The router's last reading that the bar keeps while the owner types on in that sentence: an "understand" or "chart" ask.
    var routed: (sentence: String, label: String)?
    /// The current line holds a secret (a key, a seed phrase, a password, a code). No AI for that line; the bar says so quietly.
    @Published var secretLine = false
    /// The lines typed in this conversation, in memory only, for the router's context.
    private(set) var memory = TypingMemory()
    /// "send 5 USDC to ana.testnet": the chip that proposes it for approval in the app. See KeyboardModel+Pay.
    @Published var payOffer: PayDraft? { didSet { noteChipsShown() } }
    /// A payment the app sent: the bar offers its Insert line.
    @Published var paySent: PaySent?
    /// The keyboard's own approval card (design C), in place of the keys.
    @Published var payPanel: PayPanel?
    var payTask: Task<Void, Never>?
    /// Payments already proposed from this text, so the chip does not come back after the tap.
    var payDone: Set<PayDraft> = []
    /// "send 5 USDC to 0x… on base": the server's reading, or why cross-chain cannot run here. See KeyboardModel+Pay.
    @Published var xchainOffer: XchainOffer? { didSet { noteChipsShown() } }
    var xchainTask: Task<Void, Never>?
    /// The words last sent to /v1/pay/xchain/parse, and the ones already tapped, so each is asked and offered once.
    var xchainAsked: String?
    var xchainDone: Set<String> = []
    /// The explain card or the visual panel, in place of the keys. Nil when the keys show.
    @Published var explainPanel: ExplainPanel?
    /// The calendar panel, in place of the keys. See KeyboardModel+Calendar.
    @Published var calendar: CalendarPanel?
    var calendarUndoTask: Task<Void, Never>?
    // Explain state, kept here because extensions cannot hold stored properties.
    var explainTask: Task<Void, Never>?
    var visualTask: Task<Void, Never>?
    /// The question the server is answering now, so one pause sends it once.
    var explainPending: String?
    var explainCache: [String: ExplainResponse] = [:]
    var ratesTask: Task<Void, Never>?
    /// When the keyboard last asked for currency rates, so a currency ask reads them at most every few minutes.
    var ratesAskedAt: Date?
    /// The currency rates, read from the store once and then kept here, so no key decodes rates.json.
    var ratesKept: Calc.Rates??
    /// The drawing page in the visual panel, while it is on screen.
    weak var visualPage: VisualPage?
    /// Keeps the voice and the drawing in step while "Play with voice" is on.
    var narration: NarrationSync?
    /// The drawing's PNG and JPEG link preview, made when it finished drawing, so Send only has to upload them.
    var sharePrepared: (png: Data, preview: Data?)?
    /// The Send waiting for its upload. A late answer for an older Send is dropped.
    var shareAttempt: UUID?

    weak var host: TextHost?
    /// False in the intro scenes, which script the bar themselves. Then typing sends nothing.
    var suggestsWhileTyping = true
    let deps: KeyboardDeps
    private var suggestTask: Task<Void, Never>?
    /// The one router call in flight; new keys cancel it.
    private var routeTask: Task<Void, Never>?
    /// The text before the cursor on the last edit, to keep the line that was just sent or ended.
    private var lastBefore = ""
    /// The last Fix, kept quietly: backspace right after it puts the typed text back. No line says it was fixed.
    private var quietFixUndo: WriteUndo?
    private var lastSent = ""
    private var suggest = SuggestPolicy()
    private var actions: [ActionShortcut] = ActionShortcut.defaults
    private var writeTask: Task<Void, Never>?
    /// Rewrite calls still running. A batch leaves once its stream ends or it times out.
    private(set) var rewriteBatches: [TaskBatch] = []
    /// A version with no answer by then shows Retry. The whole list gives up at the timeout.
    static let rewriteStall: Duration = .seconds(4)
    static let rewriteTimeout: Duration = .seconds(8)
    static var rewriteFailed: String { "Couldn't reach \(AppConfig.displayName). Tap Retry." }
    private var undoTask: Task<Void, Never>?
    private var smartTask: Task<Void, Never>?
    private var addedTask: Task<Void, Never>?
    /// Smart chips added from the current text, so they do not come back after the tap.
    /// Chips added for this text. A chip read again matches by kind and trigger, so "in 20 min" does not come back as a new time.
    private var smartDone: Set<SmartChip> = []
    /// Device chips the server gave for a sentence, kept while the owner types on in that sentence.
    private var serverSmart: (sentence: String, chips: [SmartChip])?
    /// The last text Fix returned or found clean, so the chip does not offer the same text twice.
    private var lastFixed = ""
    private var fixTask: Task<Void, Never>?
    /// No chip shows before this time: 10 s after ✕, 5 s after typing past a chip.
    private var quietUntil: Date?
    /// The text when the owner tapped ✕. No chip comes back while the field still holds it.
    private var dismissedText: String?
    /// When a chip first showed and how many words were typed then, for the typed-past rule.
    private var chipSeen: (at: Date, words: Int)?
    /// The copy the keyboard is offering and when it first saw it.
    private var copiedSeen: (change: Int, at: Date)?
    private var copiedTask: Task<Void, Never>?
    static let undoWindow: Duration = .seconds(5)
    private let log = Logger(subsystem: "com.orseliyas.pip", category: "keyboard")
    static let pasteTimeout: TimeInterval = 8

    private var rejected: AnyCancellable?

    init(deps: KeyboardDeps = .live()) {
        self.deps = deps
        // The server refused the session (a 401 outside /v1/auth/). The keyboard does not wipe the phone: the app does that.
        // It drops what it holds in memory and asks the owner to open the app.
        rejected = NotificationCenter.default.publisher(for: APIClient.tokenRejected)
            .map { $0.userInfo?["epoch"] as? String }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] epoch in self?.sessionRejected(epoch: epoch) }
    }

    /// A late answer from before the last wipe or sign-in does nothing.
    func sessionRejected(epoch: String?) {
        guard epoch == deps.store.accountEpoch else { return }
        forgetMemory()
        paired = false
    }

    func refreshAccess() {
        hasFullAccess = host?.hasFullAccess ?? false
        paired = hasFullAccess && deps.store.signedIn
        returnStyle = ReturnStyle(host?.returnKeyType ?? .default)
        let kind = FieldKind(keyboardType: host?.keyboardType ?? .default, contentType: host?.textContentType)
        if kind != field { field = kind; layout = kind.layout; memory.clear() }
        let empty = (host?.contextBeforeInput ?? "").isEmpty && (host?.contextAfterInput ?? "").isEmpty
        returnEnabled = !(host?.enablesReturnKeyAutomatically == true && empty)
    }

    // MARK: keys (touch model of the system keyboard)

    private var active: [ObjectIdentifier: KeyCap] = [:]
    private var points: [ObjectIdentifier: CGPoint] = [:]
    private var lastShiftTap: Date?
    private var lastSpaceTap: Date?
    private var deleteTask: Task<Void, Never>?
    /// The long-press timer of the newest letter or Return.
    private var holdTask: Task<Void, Never>?
    /// The finger whose held Return already typed a new line, so its lift types nothing.
    private var returnHeld: ObjectIdentifier?
    /// Where the finger went down on space, for the trackpad.
    private var spaceStart: (id: ObjectIdentifier, x: CGFloat, at: Date)?
    private var slide: (id: ObjectIdentifier, lastX: CGFloat, lastAt: Date, carry: CGFloat)?
    /// The keyboard's width, set by the view on each touch, so the accent popup stays inside it.
    var keyboardWidth: CGFloat = 390

    static let accentDelay: Duration = .milliseconds(320)
    static let returnHoldDelay: Duration = .milliseconds(400)
    static let deleteRepeatDelay: Duration = .milliseconds(450)
    static let deleteSlow: Duration = .milliseconds(90)
    static let deleteFast: Duration = .milliseconds(45)
    /// Characters deleted at the slow rate before the fast one.
    static let deleteFastAfter = 18
    /// How far a finger may slide off delete before the repeat stops.
    static let deleteSlideOff: CGFloat = 20
    /// How far along space the finger moves before the trackpad starts.
    static let slideStart: CGFloat = 10
    /// How far the finger moves for the cursor to move one character, when slow.
    static let cursorStep: CGFloat = 9
    /// Above this speed (pt/s) a flick moves further, up to `maxFlickGain` times.
    static let flickSpeed: CGFloat = 250
    static let maxFlickGain: CGFloat = 2.5
    static let slotDelay: Duration = .milliseconds(30)

    /// The last autocorrect: what was typed, what replaced it, and the key after it.
    private var correction: (typed: String, fixed: String, boundary: String)?
    /// Words put back after an autocorrect, or tapped as typed. They are not fixed again.
    private var keptWords: Set<String> = []
    private var nextWord = NextWord()
    private var slotTask: Task<Void, Never>?
    private lazy var haptics = deps.haptics()
    /// "Key haptics" in the app, read when the keyboard appears. Only with Full Access.
    private var hapticsOn = false
    private let signposter = OSSignposter(subsystem: "com.orseliyas.pip", category: "keys")

    /// The English model for the touch decoder and completions, loaded once off the main thread.
    private(set) static var language: LanguageModel?
    /// The load running now. A memory warning does not clear it, so a second load never starts beside it.
    private static var languageLoad: UUID?
    /// The load whose model is kept. A memory warning clears it; the next appear asks for the running load again.
    private static var languageWanted: UUID?
    private var adaptation = TouchAdaptation()
    /// What the decoder made of each finger now down.
    private var tapInfo: [ObjectIdentifier: (result: TouchDecoder.Result, point: CGPoint)] = [:]
    /// Each letter tap's likeliest keys in the word being typed; empty for a letter typed some other way.
    private var wordTaps: [[TouchDecoder.Candidate]] = []
    /// The last decoded tap. It teaches the adaptation once the next key is not delete.
    private var unlearned: (point: CGPoint, key: TouchKey)?

    static func loadLanguage(_ make: @escaping @Sendable () -> LanguageModel? = { LanguageModel.bundled() }) {
        guard language == nil else { return }
        if let running = languageLoad { languageWanted = running; return }
        let token = UUID()
        languageLoad = token
        languageWanted = token
        Task.detached(priority: .utility) {
            let model = make()
            await MainActor.run {
                // A memory warning during the load, with no appear after it: drop this model too.
                if languageWanted == token { KeyboardModel.language = model }
                languageLoad = nil
            }
        }
    }

    /// A memory warning: drop what reloads by itself. Typing keeps working with plain key edges
    /// until keyboardAppeared loads the language model again.
    func releaseCaches() {
        Self.language = nil
        Self.languageWanted = nil
    }

    /// The key a touch means: the key under it or, for a letter tapped near its edge, the likeliest letter there.
    /// The keys never move on screen; the balloon shows the decoded letter.
    func key(for id: ObjectIdentifier, at p: CGPoint, in keys: [KeyCap]) -> KeyCap? {
        guard let hit = KeyboardGeometry.key(at: p, in: keys) else { return nil }
        // A new finger types the letter another finger still holds first, so the decoder reads it as context.
        if active[id] == nil, slide == nil { rollover(except: id) }
        tapInfo[id] = nil
        guard layout == .letters, case .char = hit.kind,
              let r = TouchDecoder.decode(p, keys: KeyboardGeometry.touchKeys(keys), word: currentWord, model: Self.language, adaptation: adaptation),
              let key = keys.first(where: { $0.kind == .char(String(r.key.letter)) }) else { return hit }
        tapInfo[id] = (r, p)
        return key
    }

    /// The letters of the word before the cursor, lowercased.
    private var currentWord: String {
        String((host?.contextBeforeInput ?? "").lowercased().reversed().prefix { LanguageModel.index($0) != nil }.reversed())
    }

    private func learnLastTap() {
        guard let u = unlearned else { return }
        unlearned = nil
        adaptation.learn(u.point, on: u.key)
    }

    func display(_ c: String) -> String { layout == .letters && shift != .off ? c.uppercased() : c }

    private func keyHaptic(_ strength: HapticStrength) {
        if hapticsOn { haptics.tap(strength) }
    }

    func touchBegan(_ id: ObjectIdentifier, _ key: KeyCap, at point: CGPoint = .zero) {
        let state = signposter.beginInterval("touchBegan")
        defer { signposter.endInterval("touchBegan", state) }
        // While space is a trackpad, other fingers type nothing.
        guard slide == nil else { return }
        host?.playClick()
        keyHaptic(.light)
        rollover(except: id)
        active[id] = key
        points[id] = point
        pressedKeys.insert(key.id)
        switch key.kind {
        case .char(let c):
            calloutKeyID = key.id
            holdLetter(id, key, c)
        case .delete: deleteDown()
        case .ret: holdReturn(id)
        case .space: spaceStart = (id, point.x, deps.now())
        default: break
        }
    }

    /// A new touch types any letter still held by another finger, like iOS.
    private func rollover(except id: ObjectIdentifier) {
        for (other, k) in active where other != id {
            guard case .char = k.kind else { continue }
            let tap = tapInfo[other]
            let popup = accents?.touch == other ? accents : nil
            release(other)
            if let popup { commitAccent(popup) } else { commit(k, tap: tap) }
        }
    }

    func touchMoved(_ id: ObjectIdentifier, _ key: KeyCap, at point: CGPoint = .zero) {
        points[id] = point
        guard let current = active[id] else { return }
        if current.kind == .space { slideSpace(id, to: point); return }
        if let a = accents, a.touch == id { accents?.selected = AccentPopup.index(point.x, a.cells); return }
        if current.kind == .delete {
            if !current.frame.insetBy(dx: -Self.deleteSlideOff, dy: -Self.deleteSlideOff).contains(point) { deleteTask?.cancel() }
            return
        }
        guard current.id != key.id, case .char = current.kind, case .char(let c) = key.kind else { return }
        pressedKeys.remove(current.id)
        active[id] = key
        pressedKeys.insert(key.id)
        calloutKeyID = key.id
        holdLetter(id, key, c)
    }

    func touchEnded(_ id: ObjectIdentifier) {
        let state = signposter.beginInterval("touchEnded")
        defer { signposter.endInterval("touchEnded", state) }
        guard let key = active[id] else { return }
        let tap = tapInfo[id]
        let popup = accents?.touch == id ? accents : nil
        release(id)
        if slide?.id == id { endSlide(); return }
        if let popup { commitAccent(popup); return }
        if key.kind == .delete { deleteTask?.cancel(); return }
        if key.kind == .ret, returnHeld == id { returnHeld = nil; return }
        commit(key, tap: tap)
    }

    func touchCancelled(_ id: ObjectIdentifier) {
        if active[id]?.kind == .delete { deleteTask?.cancel() }
        release(id)
        if slide?.id == id { endSlide() }
    }

    /// VoiceOver activation and tests without touches.
    func activate(_ key: KeyCap) {
        host?.playClick()
        if key.kind == .delete { deleteOnce(); return }
        commit(key)
    }

    private func release(_ id: ObjectIdentifier) {
        points[id] = nil
        tapInfo[id] = nil
        if accents?.touch == id { accents = nil }
        if spaceStart?.id == id { spaceStart = nil }
        if let k = active.removeValue(forKey: id) {
            pressedKeys.remove(k.id)
            if calloutKeyID == k.id { calloutKeyID = nil }
            if case .char = k.kind { holdTask?.cancel() }
            if k.kind == .ret { holdTask?.cancel() }
        }
    }

    // MARK: long-press

    /// Held still for 0.32 s, a letter with accents opens the popup. Slide to pick; lift types the pick.
    private func holdLetter(_ id: ObjectIdentifier, _ key: KeyCap, _ c: String) {
        holdTask?.cancel()
        let options = Accents.options(c)
        guard layout == .letters, !options.isEmpty else { return }
        let sleep = deps.sleep
        holdTask = Task { [weak self] in
            try? await sleep(Self.accentDelay)
            guard let self, !Task.isCancelled, self.active[id]?.id == key.id else { return }
            let cells = AccentPopup.cells(key: key.frame, count: options.count, width: self.keyboardWidth)
            self.accents = AccentPopup(touch: id, keyID: key.id, options: options, cells: cells,
                                       selected: AccentPopup.index(self.points[id]?.x ?? key.frame.midX, cells))
            self.calloutKeyID = nil
            self.keyHaptic(.medium)
        }
    }

    private func commitAccent(_ popup: AccentPopup) {
        accents = nil
        commit(KeyCap(id: popup.keyID, kind: .char(popup.options[popup.selected]), frame: .zero, a11y: ""))
    }

    /// Return held for 0.4 s types a new line, even in a field whose Return sends.
    private func holdReturn(_ id: ObjectIdentifier) {
        holdTask?.cancel()
        guard returnEnabled else { return }
        let sleep = deps.sleep
        holdTask = Task { [weak self] in
            try? await sleep(Self.returnHoldDelay)
            guard let self, !Task.isCancelled, self.active[id]?.kind == .ret else { return }
            self.returnHeld = id
            self.keyHaptic(.medium)
            self.host?.insert("\n")
            self.lastSpaceTap = nil
            self.afterEdit()
        }
    }

    // MARK: space-bar trackpad

    /// Sliding along space moves the cursor by whole characters. A fast flick moves further.
    private func slideSpace(_ id: ObjectIdentifier, to p: CGPoint) {
        let now = deps.now()
        if slide == nil {
            guard let s = spaceStart, s.id == id, abs(p.x - s.x) >= Self.slideStart else { return }
            slide = (id, s.x, s.at, 0)
            trackpad = true
            lastSpaceTap = nil
            keyHaptic(.light)
        }
        guard var s = slide else { return }
        let dx = p.x - s.lastX
        let dt = CGFloat(now.timeIntervalSince(s.lastAt))
        let speed = dt > 0 ? abs(dx) / dt : 0
        let gain = min(max(speed / Self.flickSpeed, 1), Self.maxFlickGain)
        s.carry += dx * gain / Self.cursorStep
        // A hair of slack, so 45 pt in two moves is 5 steps and not 4.999.
        let steps = Int(s.carry + (s.carry < 0 ? -1e-6 : 1e-6))
        s.carry -= CGFloat(steps)
        s.lastX = p.x
        s.lastAt = now
        slide = s
        if steps != 0 { moveCursor(steps) }
    }

    /// Moves the cursor by `steps` whole characters, so an emoji or an accent is one step.
    private func moveCursor(_ steps: Int) {
        guard let host else { return }
        let offset = steps < 0
            ? -String((host.contextBeforeInput ?? "").suffix(-steps)).utf16.count
            : String((host.contextAfterInput ?? "").prefix(steps)).utf16.count
        if offset != 0 { host.adjustCursor(by: offset) }
    }

    private func endSlide() {
        slide = nil
        trackpad = false
        lastSpaceTap = nil
        afterEdit()
    }

    // MARK: commit

    /// `tap`: what the decoder made of the touch that typed it.
    private func commit(_ key: KeyCap, tap: (result: TouchDecoder.Result, point: CGPoint)? = nil) {
        correction = nil
        learnLastTap()
        switch key.kind {
        case .char(let c):
            let fixed = Self.wordEnders.contains(c) ? autocorrect() : nil
            host?.insert(display(c))
            correction = fixed.map { ($0.typed, $0.fixed, c) }
            if c.count == 1, LanguageModel.index(Character(c)) != nil {
                wordTaps.append(tap?.result.candidates ?? [])
                unlearned = tap.map { ($0.point, $0.result.key) }
            } else {
                wordTaps = []
            }
            if shift == .once && layout == .letters { shift = .off }
            if layout != .letters && layout != .digits && c == "'" { layout = .letters }
            lastSpaceTap = nil
            afterEdit()
        case .shift:
            let now = deps.now()
            if shift == .locked { shift = .off }
            else if let last = lastShiftTap, now.timeIntervalSince(last) < 0.35 { shift = .locked }
            else { shift = shift == .off ? .once : .off }
            lastShiftTap = now
        case .mode(let to):
            layout = to
        case .space:
            if expandShortcut() { break }
            let fixed = autocorrect()
            tapSpace()
            correction = fixed.map { ($0.typed, $0.fixed, " ") }
            wordTaps = []
            nextWord.learn(host?.contextBeforeInput ?? "")
        case .ret:
            guard returnEnabled else { break }
            if expandShortcut() { break }
            let fixed = autocorrect()
            host?.insert("\n")
            correction = fixed.map { ($0.typed, $0.fixed, "\n") }
            wordTaps = []
            lastSpaceTap = nil
            afterEdit()
        case .globe:
            host?.nextKeyboard()
        case .delete:
            break
        }
    }

    static let wordEnders: Set<String> = [",", ".", "!", "?", ";", ":"]

    /// Autocorrect runs only where the field and its type allow it.
    private var autocorrects: Bool { field.autocorrects && host?.autocorrection != .no }

    /// Fixes a clear typo in the word just typed, before space, return or punctuation goes in.
    private func autocorrect() -> (typed: String, fixed: String)? {
        guard autocorrects, let host else { return nil }
        let taps = wordTaps.contains(where: \.isEmpty) ? nil : wordTaps
        let decode: ((String) -> String?)? = Self.language.map { m in { TouchDecoder.correctWord($0, taps: taps, model: m) } }
        guard let c = FixCheck.autocorrect(host.contextBeforeInput ?? "", kept: keptWords, decode: decode) else { return nil }
        for _ in 0..<c.typed.count { host.deleteBackward() }
        host.insert(c.fixed)
        return c
    }

    /// Backspace right after an autocorrect puts the typed word back, and it stays as typed from then on.
    private func revertCorrection() -> Bool {
        guard let c = correction, let host, (host.contextBeforeInput ?? "").hasSuffix(c.fixed + c.boundary) else { return false }
        correction = nil
        for _ in 0..<(c.fixed.count + c.boundary.count) { host.deleteBackward() }
        host.insert(c.typed)
        keptWords.insert(c.typed.lowercased())
        return true
    }

    // MARK: word slots

    /// Refreshes the word slots once the keys pause for 30 ms. The work runs off the main thread;
    /// a result for text that has changed since is dropped.
    private func scheduleWordSlots() {
        slotTask?.cancel()
        // The intro scenes script the bar themselves.
        guard field.wordSlots, suggestsWhileTyping, let host else {
            if words != WordRow() { words = WordRow() }
            return
        }
        let input = WordRow.Input(before: host.contextBeforeInput ?? "", kept: keptWords,
                                  taps: wordTaps.contains(where: \.isEmpty) ? nil : wordTaps,
                                  autocorrects: autocorrects, next: nextWord)
        let sleep = deps.slotSleep
        slotTask = Task { [weak self] in
            try? await sleep(Self.slotDelay)
            guard !Task.isCancelled else { return }
            let lm = Self.language
            let row = await Task.detached(priority: .userInitiated) { WordRow.compute(input, model: lm) }.value
            guard let self, !Task.isCancelled, (self.host?.contextBeforeInput ?? "") == input.before else { return }
            if self.words != row { self.words = row }
        }
    }

    /// The three word slots own the bar while a word is half typed, and after a space when no chip shows.
    /// An answer chip (a sum, a meaning) always wins over them. The tool icons step aside for the slots.
    var showsWordSlots: Bool {
        guard !words.slots.isEmpty, !notesOpen, !writeOpen, explainPanel == nil, explainOffer == nil, drawTopic == nil, payOffer == nil, xchainOffer == nil, paySent == nil, payPanel == nil, undo == nil else { return false }
        if case .idle = bar {} else { return false }
        return words.midWord || barItems.isEmpty
    }

    /// A tap on a word slot: it replaces the word being typed (or follows the space), then a space.
    /// The typed word, tapped as typed, is kept from then on.
    func useWord(_ word: String) {
        guard let host else { return }
        host.playClick()
        keyHaptic(.light)
        if let typed = Predictions.typedWord(host.contextBeforeInput ?? "") {
            for _ in 0..<typed.count { host.deleteBackward() }
            if word == typed { keptWords.insert(typed.lowercased()) }
        }
        host.insert(word + " ")
        nextWord.learn(host.contextBeforeInput ?? "")
        correction = nil
        unlearned = nil
        wordTaps = []
        lastSpaceTap = nil
        afterEdit()
    }

    /// Double space after a word types ". ", like iOS. Space in 123 or #+= goes back to letters.
    private func tapSpace() {
        let now = deps.now()
        let before = host?.contextBeforeInput ?? ""
        if let last = lastSpaceTap, now.timeIntervalSince(last) < 0.45, before.hasSuffix(" "),
           let prev = before.dropLast().last, prev.isLetter || prev.isNumber {
            host?.deleteBackward()
            host?.insert(". ")
            lastSpaceTap = nil
        } else {
            host?.insert(" ")
            lastSpaceTap = now
        }
        if layout != .letters { layout = .letters }
        afterEdit()
    }

    private func deleteOnce() {
        if let u = quietFixUndo {
            quietFixUndo = nil
            if replace(u.replacement, with: u.original) {
                lastFixed = u.original.trimmingCharacters(in: .whitespaces)
                afterEdit()
                return
            }
        }
        if revertCorrection() { wordTaps = [] } else { host?.deleteBackward(); _ = wordTaps.popLast() }
        correction = nil
        unlearned = nil
        afterEdit()
    }

    /// Delete fires on touch down, repeats after 0.45 s at 90 ms a character, then 45 ms after 18 characters.
    private func deleteDown() {
        deleteOnce()
        deleteTask?.cancel()
        let sleep = deps.sleep
        deleteTask = Task { [weak self] in
            try? await sleep(Self.deleteRepeatDelay)
            var n = 0
            while !Task.isCancelled, let self {
                self.wordTaps = []
                self.host?.deleteBackward()
                self.afterEdit()
                n += 1
                try? await sleep(n < Self.deleteFastAfter ? Self.deleteSlow : Self.deleteFast)
            }
        }
    }

    private func afterEdit() { textChanged() }

    /// Auto-capitalization follows the field's autocapitalizationType. Caps lock stays until tapped.
    func updateAutoShift() {
        guard shift != .locked else { return }
        let raw = host?.contextBeforeInput ?? ""
        let on: Bool
        switch host?.autocapitalization ?? .sentences {
        case .none: on = false
        case .allCharacters: on = true
        case .words: on = raw.isEmpty || raw.last?.isWhitespace == true
        default: on = raw.trimmingCharacters(in: .whitespaces).isEmpty || [". ", "! ", "? ", "\n"].contains { raw.hasSuffix($0) }
        }
        shift = on ? .once : .off
    }

    // MARK: lifecycle

    /// On appear: note that the keyboard is on, and offer copied text (without reading it).
    func keyboardAppeared() {
        forgetIfAccountChanged()
        refreshAccess()
        layout = field.layout
        updateAutoShift()
        Self.loadLanguage()
        hapticsOn = hasFullAccess && deps.store.keyHaptics
        if hapticsOn { haptics.prepare() }
        scheduleWordSlots()
        guard hasFullAccess else { copiedAvailable = false; return }
        deps.store.keyboardLastSeen = deps.now()
        reloadShortcuts()
        guard paired else { return }
        reloadSnapshot()
        reloadPaySent()
        // A new field starts clean, cooldowns too.
        quietUntil = nil
        dismissedText = nil
        chipSeen = nil
        offerCopied()
    }

    /// "Use copied message" for 3 minutes after the keyboard first saw the copy, and once: use, ✕, typing or the time ends it.
    /// hasStrings and changeCount do not trigger the paste prompt; only reading the string does.
    private func offerCopied() {
        let pasteboard = deps.pasteboard
        let change = pasteboard.changeCount
        guard pasteboard.hasStrings, change != deps.store.lastPasteboardChange else { copiedAvailable = false; return }
        let now = deps.now()
        if copiedSeen?.change != change { copiedSeen = (change, now) }
        let left = (copiedSeen?.at ?? now).addingTimeInterval(ChipTiming.copiedLife).timeIntervalSince(now)
        guard left > 0 else { endCopied(); return }
        copiedAvailable = true
        copiedTask?.cancel()
        let sleep = deps.sleep
        copiedTask = Task { [weak self] in
            try? await sleep(.milliseconds(Int(left * 1000)))
            guard !Task.isCancelled else { return }
            self?.endCopied()
        }
    }

    /// The copy is used up: it is not offered again.
    private func endCopied() {
        copiedTask?.cancel()
        if let s = copiedSeen { deps.store.lastPasteboardChange = s.change }
        copiedAvailable = false
    }

    /// What the app last wrote for the ready chips: today's appointments.
    private func reloadSnapshot() {
        appointments = deps.store.appointments
    }

    /// The app wiped the phone (logout or account delete) since this keyboard last looked: drop the previous person's state.
    func forgetIfAccountChanged() {
        let epoch = deps.store.accountEpoch
        guard epoch != deps.store.keyboardSeenEpoch else { return }
        deps.store.keyboardSeenEpoch = epoch
        forgetAccount()
    }

    /// A new model when the app wiped the phone since this one last looked, else nil. The keyboard swaps it in on appear,
    /// so nothing of the previous person survives in memory. This model first stops its tasks and wipes this process's caches.
    /// A keyboard that stays up across a logout still gets `forgetIfAccountChanged` on each text change.
    func replacementIfAccountChanged() -> KeyboardModel? {
        guard deps.store.accountEpoch != deps.store.keyboardSeenEpoch else { return nil }
        forgetIfAccountChanged()
        return KeyboardModel(deps: deps)
    }

    /// Everything this keyboard holds in memory from the previous person, then this process's caches on disk.
    func forgetAccount() {
        forgetMemory()
        let wipe = deps.wipeProcess
        Task { await wipe() }
    }

    /// Everything this keyboard holds in memory about the account: notes, cached answers, chips, writing state.
    func forgetMemory() {
        closeExplain()
        resetWriting()
        for t in [suggestTask, routeTask, smartTask, addedTask, explainTask, fixTask, copiedTask] { t?.cancel() }
        memory.clear()
        drawTopic = nil
        routed = nil
        explainTask = nil
        explainPending = nil
        explainCache = [:]
        explainOffer = nil
        payTask?.cancel()
        xchainTask?.cancel()
        payOffer = nil
        xchainOffer = nil
        xchainAsked = nil
        xchainDone = []
        paySent = nil
        payDone = []
        payPanel = nil
        sharePrepared = nil
        shareAttempt = nil
        narration = nil
        notes = []
        notesOpen = false
        closeCalendar()
        appointments = []
        actions = ActionShortcut.defaults
        smart = []
        added = nil
        smartDone = []
        serverSmart = nil
        keptWords = []
        nextWord = NextWord()
        words = WordRow()
        fixPlan = nil
        lastSent = ""
        lastLatencyMs = nil
        copiedAvailable = false
        copiedSeen = nil
        quietUntil = nil
        dismissedText = nil
        chipSeen = nil
        bar = .idle
    }

    func keyboardDisappeared() {
        holdTask?.cancel()
        deleteTask?.cancel()
        slotTask?.cancel()
        fixTask?.cancel()
        slide = nil
        trackpad = false
        accents = nil
        notesOpen = false
        closeCalendar()
        closeExplain()
        resetWriting()
        routeTask?.cancel()
        memory.clear()
        lastBefore = ""
        if case .working = bar { bar = .idle }
    }

    // MARK: notes

    var typed: String { (host?.contextBeforeInput ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }

    func toggleNotes() {
        forgetIfAccountChanged()
        host?.playClick()
        writeOpen = false
        closeCalendar()
        if !notesOpen { notes = deps.store.notes }
        notesOpen.toggle()
    }

    /// A note goes into the field as it is. It is not sent for suggestions.
    func insertNote(_ note: Note) {
        host?.playClick()
        let before = host?.contextBeforeInput ?? ""
        host?.insert((before.last?.isWhitespace ?? true ? "" : " ") + note.text)
        lastSent = typed
        notesOpen = false
        updateAutoShift()
    }

    var canSaveNote: Bool { !typed.isEmpty && !notes.contains { $0.text == typed } }

    /// "+" keeps the text before the cursor as a new note, on this device.
    func saveNote() {
        forgetIfAccountChanged()
        guard canSaveNote else { return }
        host?.playClick()
        notes.insert(Note(text: typed), at: 0)
        deps.store.notes = notes
    }

    // MARK: suggestions

    /// Called on every edit, from our keys and from textDidChange.
    func textChanged() {
        // A logout while the keyboard stayed on screen: forget before anything is read or written.
        forgetIfAccountChanged()
        refreshAccess()
        updateAutoShift()
        let text = typed
        let before = host?.contextBeforeInput ?? ""
        if Flags.memory { rememberLine(before) }
        let line = before.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
        let secret = Flags.router && !line.isEmpty && SecretFilter.isSecret(line)
        if secretLine != secret { secretLine = secret }
        if let u = quietFixUndo, !before.hasSuffix(u.replacement) { quietFixUndo = nil }
        typedPast(text)
        let quiet = chipsQuiet(text)
        updateFixable(quiet: quiet || secret)
        scheduleWordSlots()
        if let u = undo, !(host?.contextBeforeInput ?? "").hasSuffix(u.replacement) { undo = nil }
        // The dictionary needs no pairing and no network, so a meaning shows even before pairing.
        if !paired, suggestsWhileTyping { if quiet { clearExplainOffer() } else { updateExplain(text) } }
        guard paired, suggestsWhileTyping else { return }
        if case .working = bar { return }
        // An explain question is answered by the dictionary or /v1/explain, so it never also goes to /v1/suggest.
        let explaining: Bool
        if quiet { clearExplainOffer(); explaining = false } else { explaining = updateExplain(text) }
        let wasEmpty = fieldEmpty
        fieldEmpty = text.isEmpty
        // Empty again, as after a send: the ready chips read the app's latest snapshot.
        if text.isEmpty, !wasEmpty { reloadSnapshot() }
        let clear = detectSmart(text, quiet: quiet)
        let paying = updatePay(text, quiet: quiet)
        guard text != lastSent else { return }
        suggestTask?.cancel()
        lastSent = text
        bar = .idle
        // Typing ends the copied-text offer.
        if !text.isEmpty, copiedAvailable { endCopied() }
        routeTask?.cancel()
        if !Flags.router {
            if !quiet, !explaining, !paying, let sentence = suggest.maybe(text, clear: clear, field: field) { requestSuggest(sentence, typed: text) }
        } else if !quiet, !secret, !explaining, !paying, let sentence = suggest.route(text, clear: clear, field: field) {
            requestRoute(sentence, typed: text)
        }
    }

    /// Keeps a line in the typing memory once it is done: the field emptied (sent) or a new line started.
    private func rememberLine(_ before: String) {
        defer { lastBefore = before }
        let last = lastBefore.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
        guard !last.isEmpty else { return }
        if before.isEmpty || (before.hasSuffix("\n") && before.count > lastBefore.count) { memory.add(last) }
    }

    // MARK: chip life: ✕, cooldowns, typed past

    /// True while no chip may show: the 10 s after ✕ (and the text it was tapped on), the 5 s after typing past a chip.
    private func chipsQuiet(_ text: String) -> Bool {
        if let until = quietUntil {
            if deps.now() < until { return true }
            quietUntil = nil
        }
        if let d = dismissedText {
            if d == text { return true }
            dismissedText = nil
        }
        return false
    }

    /// Two new words typed past a chip that showed for at least 1 s and was not used: no chip for 5 s.
    private func typedPast(_ text: String) {
        guard let seen = chipSeen else { return }
        let now = deps.now()
        guard now.timeIntervalSince(seen.at) >= ChipTiming.typedPastSeen,
              ChipTiming.words(text) - seen.words >= ChipTiming.typedPastWords else { return }
        quietUntil = now.addingTimeInterval(ChipTiming.typedPastQuiet)
        clearChips()
    }

    /// Notes when a chip about the typing first shows, so typing on past it can be counted.
    private func noteChipsShown() {
        let visible = !smart.isEmpty || explainOffer != nil || drawTopic != nil || payOffer != nil || xchainOffer != nil
        if !visible { chipSeen = nil } else if chipSeen == nil { chipSeen = (deps.now(), ChipTiming.words(typed)) }
    }

    /// ✕ on the bar: every chip goes, none comes back for 10 s, and none while the text stays the same.
    func dismissChips() {
        host?.playClick()
        quietUntil = deps.now().addingTimeInterval(ChipTiming.dismissQuiet)
        dismissedText = typed
        if copiedAvailable { endCopied() }
        calmOffer = nil
        dropPaySent()
        clearChips()
    }

    private func clearChips() {
        for t in [smartTask, fixTask, suggestTask] { t?.cancel() }
        if !smart.isEmpty { smart = [] }
        if payOffer != nil { payOffer = nil }
        if xchainOffer != nil { xchainOffer = nil }
        clearExplainOffer()
        fixPlan = nil
        chipSeen = nil
    }

    /// Tap on "Use copied message". Reading may show the system paste prompt once, so the read runs
    /// off the main thread with a timeout; the keyboard never waits on it. If the message sounds upset, a calm reply waits on the bar.
    func useCopied() {
        let pasteboard = deps.pasteboard
        deps.store.lastPasteboardChange = pasteboard.changeCount
        copiedAvailable = false
        suggestTask?.cancel()
        bar = .working("Reading copied message…")
        suggestTask = Task { [weak self] in
            let copied = await Self.readPasteboard(pasteboard, timeout: Self.pasteTimeout)
            guard let self, !Task.isCancelled else { return }
            guard let copied = copied?.trimmingCharacters(in: .whitespacesAndNewlines), !copied.isEmpty else {
                self.bar = .error("Copied text not available")
                return
            }
            self.bar = .idle
            self.checkCopiedTone(String(copied.prefix(1000)))
        }
    }

    nonisolated static func readPasteboard(_ pasteboard: Pasteboard, timeout: TimeInterval) async -> String? {
        final class Once: @unchecked Sendable {
            private let lock = NSLock()
            private var cont: CheckedContinuation<String?, Never>?
            init(_ c: CheckedContinuation<String?, Never>) { cont = c }
            func resume(_ v: String?) {
                lock.lock(); let c = cont; cont = nil; lock.unlock()
                c?.resume(returning: v)
            }
        }
        return await withCheckedContinuation { cont in
            let once = Once(cont)
            DispatchQueue.global(qos: .userInitiated).async { once.resume(pasteboard.string) }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { once.resume(nil) }
        }
    }

    var nextUp: Appointment? { AppointmentRules.nextUp(appointments, now: deps.now()) }

    /// On every key, on the phone: events, reminders and notes in the typed text. True when something clear was found.
    /// A chip that no longer applies leaves on this key, and one still showing takes the new reading in place.
    /// Only a new chip waits for the fingers to settle.
    private func detectSmart(_ text: String, quiet: Bool) -> Bool {
        smartTask?.cancel()
        if text.isEmpty { smart = []; smartDone = []; serverSmart = nil; return false }
        let found = SmartDetect.detect(text, now: deps.now())
        guard !quiet else { if !smart.isEmpty { smart = [] }; return !found.isEmpty }
        let shown = smartChips(text, found: found)
        let stay = shown.filter { s in smart.contains { $0.id == s.id } }
        if stay != smart { smart = stay }
        guard shown != smart else { return !found.isEmpty }
        let sleep = deps.sleep
        let wait = ChipTiming.settle(after: host?.contextBeforeInput ?? "")
        smartTask = Task { [weak self] in
            try? await sleep(wait)
            guard let self, !Task.isCancelled else { return }
            self.smart = shown
            self.recordCaught(shown)
        }
        return !found.isEmpty
    }

    /// The chips the text holds now: the phone's reading, then the server's for this sentence while it is typed on.
    private func smartChips(_ text: String, found: [SmartChip]) -> [SmartChip] {
        let sentence = SmartDetect.lastSentence(text)
        let kept = serverSmart.flatMap { s in SuggestPolicy.continues(sentence, asked: s.sentence) ? s.chips : nil } ?? []
        return Array((found + kept.filter { k in !found.contains { $0.id == k.id } }).filter { !isDone($0) }.prefix(SmartDetect.maxChips))
    }

    private func isDone(_ chip: SmartChip) -> Bool { smartDone.contains { $0.sameReading(as: chip) } }

    /// The sentence had no clear match on the phone; the server's device chips may answer it.
    /// `typed` is the whole text it came from: the chips show only while the field still holds it. A failure stays quiet.
    private func requestSuggest(_ sentence: String, typed askedFor: String) {
        let typedAt = ContinuousClock.now
        let sleep = deps.sleep
        suggestTask = Task { [weak self] in
            try? await sleep(SuggestPolicy.debounce)
            guard let self, !Task.isCancelled else { return }
            self.suggest.markAsked(sentence)
            guard let res = try? await self.deps.api().suggest(sentence, context: nil), !Task.isCancelled else { return }
            let device = res.chips.filter { Self.deviceKinds.contains($0.kind) }
            guard !device.isEmpty, self.typed == askedFor else { return }
            let more = device.compactMap { Self.smartChip($0, sentence: sentence, now: self.deps.now()) }.filter { !self.isDone($0) }
            self.serverSmart = (sentence, more)
            self.smart = Array((self.smart + more.filter { m in !self.smart.contains { $0.id == m.id } }).prefix(SmartDetect.maxChips))
            let ms = Int((ContinuousClock.now - typedAt) / .milliseconds(1))
            self.lastLatencyMs = ms
            self.log.notice("PIP_TIMING keystroke_to_chip_ms=\(ms, privacy: .public) chips=\(more.count, privacy: .public) server_ms=\(res.timings?["total_ms"] ?? -1, privacy: .public)")
        }
    }

    /// The router: once the fingers settle (0.4 s, or 1 s mid-word), the sentence and the last 3 lines in memory go to
    /// /v1/route. One call in flight; new keys cancel it. A failure or "none" shows nothing new, and the phone's own detectors stay.
    private func requestRoute(_ sentence: String, typed askedFor: String) {
        let typedAt = ContinuousClock.now
        let sleep = deps.sleep
        let wait = ChipTiming.routeWait(after: host?.contextBeforeInput ?? "")
        let context = memory.context()
        routeTask = Task { [weak self] in
            try? await sleep(wait)
            guard let self, !Task.isCancelled else { return }
            self.suggest.markAsked(sentence)
            guard let res = try? await self.deps.api().route(sentence, context: context), !Task.isCancelled, self.typed == askedFor else { return }
            self.applyRoute(res, sentence: sentence)
            let ms = Int((ContinuousClock.now - typedAt) / .milliseconds(1))
            self.lastLatencyMs = ms
            self.log.notice("PIP_TIMING keystroke_to_route_ms=\(ms, privacy: .public) label=\(res.label, privacy: .public)")
        }
    }

    /// The router's label becomes that action's chip. The phone's parsers read the details; a label with no action yet shows nothing.
    func applyRoute(_ res: RouteResponse, sentence: String) {
        switch res.label {
        case "calendar_event", "reminder", "note":
            let more = res.chips.filter { Self.deviceKinds.contains($0.kind) }
                .compactMap { Self.smartChip($0, sentence: sentence, now: deps.now()) }.filter { !isDone($0) }
            guard !more.isEmpty else { return }
            serverSmart = (sentence, more)
            smart = Array((smart + more.filter { m in !smart.contains { $0.id == m.id } }).prefix(SmartDetect.maxChips))
        case "understand", "chart":
            guard explainOffer == nil, drawTopic == nil else { return }
            routed = (sentence, res.label)
            updateExplain(typed)
        case "pay", "xchain_pay":
            routeToPay(sentence, label: res.label)
        default:
            break
        }
    }

    /// Kinds the server answers. They run on the phone, never on the server.
    static let deviceKinds: Set<String> = ["event", "reminder", "note", "followup"]

    /// A server device chip as a smart chip. The phone fills a time the server left out from its own reading of the sentence.
    static func smartChip(_ c: Chip, sentence: String, now: Date, calendar cal: Calendar = .current) -> SmartChip? {
        let title = BarItems.string(c, "title") ?? ""
        let when = SmartDetect.findWhen(sentence, now: now, cal: cal)
        let iso = { (key: String) in BarItems.string(c, key).flatMap { ISO8601DateFormatter().date(from: $0) } }
        let trigger = c.trigger ?? when.map { String(sentence[$0.range]) } ?? String(sentence.prefix(24))
        let at9 = { (d: Date) in cal.date(bySettingHour: 9, minute: 0, second: 0, of: d) ?? d }
        switch c.kind {
        case "event":
            guard !title.isEmpty, let start = iso("start") ?? when?.date else { return nil }
            let end = iso("end") ?? ((when?.hasTime ?? true) ? start.addingTimeInterval(3600) : nil)
            return SmartChip(action: .event(title: title, start: start, end: end), trigger: trigger)
        case "reminder", "followup":
            guard !title.isEmpty else { return nil }
            let due = iso("due") ?? when.map { $0.hasTime ? $0.date : at9($0.date) } ?? at9(now.addingTimeInterval(86_400))
            return SmartChip(action: .reminder(title: title, due: due), trigger: trigger)
        case "note":
            guard let text = BarItems.string(c, "text") else { return nil }
            return SmartChip(action: .note(text: text), trigger: trigger)
        default:
            return nil
        }
    }

    // MARK: writing help (Fix, Refine, Tone check). Text leaves the phone only on a tap.

    /// The paragraph before the cursor: `text` goes to the server, `original` is what a rewrite replaces.
    private var draft: (text: String, original: String) {
        let before = host?.contextBeforeInput ?? ""
        let start = before.lastIndex(where: \.isNewline).map { before.index(after: $0) } ?? before.startIndex
        let original = String(before[start...].drop(while: \.isWhitespace))
        return (original.trimmingCharacters(in: .whitespaces), original)
    }

    /// The Fix check spell-checks every word of the draft, which is too slow for the key path (17 ms on 120 characters
    /// in the simulator). It runs off the main thread once the keys pause for 30 ms; a result for an older draft is dropped.
    /// Fix leaves as soon as the check finds the text clean. Once shown it takes each new result in place, so it never blinks.
    /// A new Fix waits for the fingers to settle: 0.4 s, or 1.0 s in the middle of a word.
    private func updateFixable(quiet: Bool = false) {
        fixTask?.cancel()
        let d = draft
        guard paired, !quiet, d.text != lastFixed, d.text.split(separator: " ").count >= 3 else { fixPlan = nil; return }
        let slotSleep = deps.slotSleep
        let sleep = deps.sleep
        let wait = ChipTiming.settle(after: host?.contextBeforeInput ?? "")
        let skipLast = d.original.last?.isLetter ?? false
        fixTask = Task { [weak self] in
            try? await slotSleep(Self.slotDelay)
            guard !Task.isCancelled else { return }
            let plan = await Task.detached(priority: .userInitiated) { FixCheck.plan(d.text, skipLast: skipLast) }.value
            guard let self, !Task.isCancelled, self.draft == d else { return }
            guard let plan else { self.fixPlan = nil; return }
            if self.fixPlan == nil {
                try? await sleep(wait)
                guard !Task.isCancelled else { return }
            }
            if self.fixPlan != plan { self.fixPlan = plan }
            self.fixPlan = plan
        }
    }

    /// The on-device fix for the draft. The chip and its tap both use this, so the tap does exactly what the chip said.
    private func localFix(_ d: (text: String, original: String)) -> FixPlan? {
        FixCheck.plan(d.text, skipLast: d.original.last?.isLetter ?? false)
    }

    /// Deletes exactly `original` before the cursor and types `new`. False when the text is no longer there.
    private func replace(_ original: String, with new: String) -> Bool {
        guard let host, (host.contextBeforeInput ?? "").hasSuffix(original) else { return false }
        for _ in 0..<original.count { host.deleteBackward() }
        host.insert(new)
        lastSent = typed
        updateAutoShift()
        return true
    }

    private func apply(_ p: WritePreview, label: String, quiet: Bool = false) {
        guard replace(p.original, with: p.text) else { bar = .error("The text changed. Try again."); return }
        lastFixed = p.text
        fixPlan = nil
        bar = .idle
        lastWrite = p.kind
        // A fix says nothing: backspace right after it puts the typed text back.
        if quiet { quietFixUndo = WriteUndo(label: label, original: p.original, replacement: p.text); return }
        undo = WriteUndo(label: label, original: p.original, replacement: p.text)
        undoTask?.cancel()
        let sleep = deps.sleep
        undoTask = Task { [weak self] in
            try? await sleep(Self.undoWindow)
            guard !Task.isCancelled else { return }
            self?.undo = nil
        }
    }

    func undoWrite() {
        guard let u = undo else { return }
        host?.playClick()
        undoTask?.cancel()
        undo = nil
        if replace(u.replacement, with: u.original) { lastFixed = u.original.trimmingCharacters(in: .whitespaces) }
    }

    /// Tap on the Fix chip, or the fix shortcut. Typos, capitals and spacing are fixed on the phone.
    /// The shortcut on text with none of those asks the server for a grammar fix.
    func fix() {
        let d = draft
        guard !d.text.isEmpty else { return }
        host?.playClick()
        suggestTask?.cancel()
        writeTask?.cancel()
        if let plan = localFix(d) {
            apply(WritePreview(kind: "fix", title: plan.title, original: d.original, text: plan.fixed), label: plan.done, quiet: true)
            return
        }
        bar = .working("Fixing\u{2026}")
        writeTask = Task { [weak self] in
            do {
                guard let res = try await self?.deps.api().fix(d.text), let self, !Task.isCancelled else { return }
                if res.text == d.text {
                    self.lastFixed = d.text
                    self.fixPlan = nil
                    self.bar = .done("Looks good \u{2713}")
                } else {
                    self.apply(WritePreview(kind: "fix", title: "Fix grammar", original: d.original, text: res.text), label: "Fixed grammar \u{2713}", quiet: true)
                }
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.bar = .error("Could not fix that. Try again.")
            }
        }
    }

    /// The Rewrite button: the panel opens and every version starts at once.
    func toggleWrite() {
        host?.playClick()
        notesOpen = false
        closeCalendar()
        cancelRewrites()
        writePanel = .menu
        writeOpen.toggle()
        if writeOpen { startRewrites() }
    }

    var canWrite: Bool { !draft.text.isEmpty }

    /// Asks for `only` (all versions by default) in one streamed call. Each row fills the moment its version arrives.
    /// A row still writing after 4 s shows Retry; after 8 s the call stops.
    func startRewrites(_ only: [RefineTone]? = nil) {
        let d = draft
        guard !d.text.isEmpty else { return }
        var list = RewriteList(original: d.original, text: d.text)
        if only != nil, case .versions(let shown) = writePanel, shown.original == d.original { list = shown }
        let tones = only ?? RefineTone.allCases
        var asked: [RefineTone: Int] = [:]
        for i in list.rows.indices where tones.contains(list.rows[i].tone) {
            list.rows[i].status = .writing
            list.rows[i].attempt += 1
            asked[list.rows[i].tone] = list.rows[i].attempt
        }
        writePanel = .versions(list)
        let api = deps.api()
        let sleep = deps.sleep
        let started = ContinuousClock.now
        let batch = TaskBatch()
        let lines = api.rewrite(d.text, tones: tones.map(\.rawValue))
        let stream = Task { [weak self] in
            do {
                for try await line in lines {
                    guard let self, !Task.isCancelled else { return }
                    self.receive(line, original: d.original, started: started)
                }
            } catch {}
            guard let self, !Task.isCancelled else { return }
            batch.cancel()
            self.rewriteBatches.removeAll { $0 === batch }
            self.settleRewrites(asked, original: d.original)
        }
        let stall = Task { [weak self] in
            try? await sleep(Self.rewriteStall)
            guard let self, !Task.isCancelled else { return }
            self.updateRewrites(d.original) { $0.stall(asked) }
        }
        let timeout = Task { [weak self] in
            try? await sleep(Self.rewriteTimeout)
            guard let self, !Task.isCancelled else { return }
            batch.cancel()
            self.rewriteBatches.removeAll { $0 === batch }
            self.settleRewrites(asked, original: d.original)
        }
        batch.tasks = [stream, stall, timeout]
        rewriteBatches.append(batch)
    }

    /// Retry on one row, or on the whole panel when nothing came back.
    func retryRewrite(_ tone: RefineTone? = nil) {
        host?.playClick()
        if let tone, case .versions = writePanel { startRewrites([tone]) } else { cancelRewrites(); startRewrites() }
    }

    private func receive(_ line: RewriteLine, original: String, started: ContinuousClock.Instant) {
        guard let tone = line.tone.flatMap(RefineTone.init(rawValue:)) else { return }
        updateRewrites(original) { l in
            if l.rows.allSatisfy({ $0.text == nil }), line.text != nil {
                let ms = Int((ContinuousClock.now - started) / .milliseconds(1))
                log.notice("PIP_TIMING tap_to_first_text_ms=\(ms, privacy: .public)")
            }
            l.set(tone, line.text.map { .ready($0) } ?? .stalled)
            if line.text != nil {
                let mark = PrivacyMark(private: line.isPrivate, attested: line.attested)
                // The weakest answer wins: one plain version means no mark.
                l.privacy = l.rows.filter({ $0.text != nil }).count == 1 ? mark : PrivacyMark.weaker(l.privacy, mark)
            }
        }
    }

    /// The call ended: rows still writing show Retry. With no version at all, the panel says so once and offers Retry.
    private func settleRewrites(_ asked: [RefineTone: Int], original: String) {
        updateRewrites(original) { $0.stall(asked) }
        if case .versions(let l) = writePanel, l.original == original, l.rows.allSatisfy({ $0.text == nil }) { writePanel = .failed(Self.rewriteFailed) }
    }

    private func updateRewrites(_ original: String, _ change: (inout RewriteList) -> Void) {
        guard case .versions(var l) = writePanel, l.original == original else { return }
        change(&l)
        writePanel = .versions(l)
    }

    private func cancelRewrites() {
        rewriteBatches.forEach { $0.cancel() }
        rewriteBatches = []
    }

    /// Tap on a version: it replaces the paragraph that was read, if the field still holds it.
    func useRewrite(_ tone: RefineTone) {
        guard case .versions(let l) = writePanel, let text = l.rows.first(where: { $0.tone == tone })?.text else { return }
        host?.playClick()
        cancelRewrites()
        writeOpen = false
        writePanel = .menu
        apply(WritePreview(kind: tone == .fix ? "fix" : "refine", title: tone.title, original: l.original, text: text), label: "Replaced \u{2713}")
    }

    /// Hold on a version: it is copied and the list stays open. The keyboard's own copy is never offered back as "Use copied message".
    func copyRewrite(_ tone: RefineTone) {
        guard case .versions(var l) = writePanel, let text = l.rows.first(where: { $0.tone == tone })?.text else { return }
        deps.pasteboard.setText(text)
        deps.store.lastPasteboardChange = deps.pasteboard.changeCount
        l.copied = tone
        writePanel = .versions(l)
    }

    func backToWriteMenu() {
        host?.playClick()
        writeTask?.cancel()
        cancelRewrites()
        writePanel = .menu
        writeOpen = false
    }

    /// Tap on the preview: it replaces the text before the cursor.
    func usePreview() {
        guard case .preview(let p) = writePanel else { return }
        host?.playClick()
        writeOpen = false
        writePanel = .menu
        if calmOffer == p { calmOffer = nil }
        apply(p, label: "Replaced \u{2713}")
    }

    /// The owner tapped "Use copied message". If the other person sounds upset, offer a calm reply.
    private func checkCopiedTone(_ copied: String) {
        let d = draft
        calmOffer = nil
        writeTask?.cancel()
        writeTask = Task { [weak self] in
            guard let res = try? await self?.deps.api().toneCheck(draft: d.text, client: copied), let self, !Task.isCancelled,
                  res.tone != "ok", let calm = res.calm else { return }
            self.calmOffer = WritePreview(kind: "tone", title: "Calm reply", original: d.original, text: calm)
        }
    }

    func openCalmOffer() {
        guard let p = calmOffer else { return }
        host?.playClick()
        notesOpen = false
        closeCalendar()
        writePanel = .preview(p)
        writeOpen = true
    }

    /// A clean slate: between intro scenes, and when the keyboard goes away.
    func resetWriting() {
        writeTask?.cancel()
        cancelRewrites()
        undoTask?.cancel()
        writeOpen = false
        writePanel = .menu
        undo = nil
        calmOffer = nil
        lastWrite = nil
        lastShortcut = nil
        lastFixed = ""
    }

    // MARK: shortcuts

    func reloadShortcuts() {
        notes = deps.store.notes
        actions = deps.store.actionShortcuts
    }

    /// The intro's shortcut scene types the first demo note's trigger. This makes sure that note answers to it.
    func addDemoShortcut() {
        let demo = Note.demo[0]
        var all = deps.store.notes
        if !all.contains(where: { $0.trigger == demo.trigger }) {
            if let i = all.firstIndex(where: { $0.text == demo.text }) { all[i].trigger = demo.trigger } else { all.insert(demo, at: 0) }
            deps.store.notes = all
        }
        reloadShortcuts()
    }

    /// Runs on space and return. If the last word is a trigger, the shortcut replaces it and the key is used up.
    private func expandShortcut() -> Bool {
        guard hasFullAccess, let host,
              let m = ShortcutEngine.match(before: host.contextBeforeInput ?? "", notes: notes, actions: actions) else { return false }
        for _ in 0..<m.delete { host.deleteBackward() }
        if case .insert(let text) = m.action { host.insert(text) }
        lastShortcut = m.trigger
        lastSent = typed
        updateAutoShift()
        updateFixable()
        if m.action == .fix { fix() }
        return true
    }

    // MARK: bar

    var barItems: [BarItems.Item] {
        let writer = deps.writer
        return BarItems.build(.init(hasFullAccess: hasFullAccess, paired: paired, undo: undo, hasCalmOffer: calmOffer != nil,
                                    bar: bar, copiedAvailable: copiedAvailable, nextUp: nextUp,
                                    smart: smart.map { BarItems.Smart(chip: $0, access: writer.access($0.place, hasFullAccess: hasFullAccess)) },
                                    added: added?.label, fieldEmpty: fieldEmpty,
                                    ready: .init(copiedAvailable: copiedAvailable, nextUp: nextUp, today: appointments), explain: explainItem,
                                    draw: drawItem, secret: secretLine, pay: payItem, paid: paidItem, now: deps.now()))
    }

    func perform(_ action: BarItems.Action) {
        switch action {
        case .useCopied: useCopied()
        case .undo: undoWrite()
        case .openCalm: openCalmOffer()
        case .smart(let chip): tapSmart(chip)
        case .undoSmart: undoSmart()
        case .today: openCalendar()
        case .notes: toggleNotes()
        case .explain: openExplainCard()
        case .draw: tapDraw()
        case .pay: tapPay()
        case .insertPaid: insertPaid()
        }
    }

    // MARK: smart chips (on the phone, no server)

    /// One tap adds it: the chip is the confirm. The bar then shows what was added, with Undo for a few seconds.
    func tapSmart(_ chip: SmartChip) {
        // The tap reads the text again: a chip the text no longer holds does nothing and goes.
        // It matches by kind and trigger, and takes the date read now: "in 20 min" counts from the tap.
        let text = typed
        guard let fresh = smartChips(text, found: SmartDetect.detect(text, now: deps.now())).first(where: { $0.sameReading(as: chip) }) else {
            smart.removeAll { $0 == chip }
            return
        }
        guard deps.writer.access(chip.place, hasFullAccess: hasFullAccess) == .ready else { return }
        let shown = chip
        let chip = fresh
        host?.playClick()
        let item: SmartAdded.Item
        do {
            switch chip.action {
            case .event(let title, let start, let end): item = .event(try deps.writer.addEvent(title: title, start: start, end: end))
            case .reminder(let title, let due): item = .reminder(try deps.writer.addReminder(title: title, due: due))
            case .note(let text):
                let note = Note(text: text)
                notes = [note] + deps.store.notes
                deps.store.notes = notes
                item = .note(note.id)
            }
        } catch {
            bar = .error("Could not add that. Try again.")
            return
        }
        smartDone.insert(chip)
        smart.removeAll { $0 == shown || $0 == chip }
        if let c = Self.caught(chip, seen: deps.now()) { deps.store.removeCaught(id: c.id) }
        added = SmartAdded(chip: chip, label: chip.doneLabel(now: deps.now()), item: item)
        addedTask?.cancel()
        let sleep = deps.sleep
        addedTask = Task { [weak self] in
            try? await sleep(Self.undoWindow)
            guard !Task.isCancelled else { return }
            self?.added = nil
        }
    }

    /// Events and reminders shown as chips go to Home's "From your chats", so the owner can add them later.
    private func recordCaught(_ chips: [SmartChip]) {
        guard hasFullAccess else { return }
        for chip in chips { if let c = Self.caught(chip, seen: deps.now()) { deps.store.recordCaught(c) } }
    }

    static func caught(_ chip: SmartChip, seen: Date) -> Caught? {
        switch chip.action {
        case .event(let title, let start, let end): Caught(title: title, place: .calendar, date: start, end: end, seen: seen)
        case .reminder(let title, let due): Caught(title: title, place: .reminder, date: due, end: nil, seen: seen)
        case .note: nil
        }
    }

    /// Removes what the last smart tap added, and offers the chip again.
    func undoSmart() {
        guard let a = added else { return }
        host?.playClick()
        addedTask?.cancel()
        added = nil
        switch a.item {
        case .event(let id): try? deps.writer.removeEvent(id)
        case .reminder(let id): try? deps.writer.removeReminder(id)
        case .note(let id):
            notes = deps.store.notes.filter { $0.id != id }
            deps.store.notes = notes
        }
        smartDone = smartDone.filter { !$0.sameReading(as: a.chip) }
        if !smart.contains(a.chip) { smart.insert(a.chip, at: 0) }
    }
}

/// Tasks that stop together: the stream, its stall timer and its timeout.
@MainActor
final class TaskBatch {
    var tasks: [Task<Void, Never>] = []
    func cancel() { tasks.forEach { $0.cancel() } }
}
