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
}

extension TextHost {
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

/// The one-tap rewrites in the Rewrite panel. The raw value is the server's tone name.
enum RefineTone: String, CaseIterable, Identifiable {
    case polite, shorter, professional, friendly, firmer
    var id: String { rawValue }
    var title: String {
        switch self {
        case .polite: "More polite"
        case .shorter: "Shorter"
        case .professional: "More professional"
        case .friendly: "Friendlier"
        case .firmer: "Firmer"
        }
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
    case busy(String)
    case preview(WritePreview)
    case message(String)
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
    /// Today's appointments, as the main app last wrote them. The keyboard never reads the calendar.
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
    @Published var smart: [SmartChip] = []
    /// The line after a smart chip was added, kept for the Undo window.
    @Published var added: SmartAdded?
    /// Nothing is typed, so the bar shows ready chips.
    @Published var fieldEmpty = true
    /// A meaning or an answer for what the last sentence asks ("what does btw mean"). See KeyboardModel+Explain.
    @Published var explainOffer: ExplainOffer?
    /// The explain card or the visual panel, in place of the keys. Nil when the keys show.
    @Published var explainPanel: ExplainPanel?
    // Explain state, kept here because extensions cannot hold stored properties.
    var explainTask: Task<Void, Never>?
    var visualTask: Task<Void, Never>?
    /// The question the server is answering now, so one pause sends it once.
    var explainPending: String?
    var explainCache: [String: ExplainResponse] = [:]
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
    private var lastSent = ""
    private var suggest = SuggestPolicy()
    private var actions: [ActionShortcut] = ActionShortcut.defaults
    private var writeTask: Task<Void, Never>?
    private var undoTask: Task<Void, Never>?
    private var smartTask: Task<Void, Never>?
    private var addedTask: Task<Void, Never>?
    /// Smart chips added from the current text, so they do not come back after the tap.
    private var smartDone: Set<SmartChip> = []
    /// Device chips the server gave for a sentence, kept while the owner types on in that sentence.
    private var serverSmart: (sentence: String, chips: [SmartChip])?
    /// The last text Fix returned or found clean, so the chip does not offer the same text twice.
    private var lastFixed = ""
    private var fixTask: Task<Void, Never>?
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
        if kind != field { field = kind; layout = kind.layout }
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
    private static var loadingLanguage = false
    private var adaptation = TouchAdaptation()
    /// What the decoder made of each finger now down.
    private var tapInfo: [ObjectIdentifier: (result: TouchDecoder.Result, point: CGPoint)] = [:]
    /// Each letter tap's likeliest keys in the word being typed; empty for a letter typed some other way.
    private var wordTaps: [[TouchDecoder.Candidate]] = []
    /// The last decoded tap. It teaches the adaptation once the next key is not delete.
    private var unlearned: (point: CGPoint, key: TouchKey)?

    static func loadLanguage() {
        guard language == nil, !loadingLanguage else { return }
        loadingLanguage = true
        Task.detached(priority: .utility) {
            let model = LanguageModel.bundled()
            await MainActor.run {
                // A memory warning during the load cleared the flag: drop this model too.
                if loadingLanguage { KeyboardModel.language = model }
                loadingLanguage = false
            }
        }
    }

    /// A memory warning: drop what reloads by itself. Typing keeps working with plain key edges
    /// until keyboardAppeared loads the language model again.
    func releaseCaches() {
        Self.language = nil
        Self.loadingLanguage = false
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
        // hasStrings and changeCount do not trigger the paste prompt; only reading the string does.
        let pasteboard = deps.pasteboard
        copiedAvailable = pasteboard.hasStrings && pasteboard.changeCount != deps.store.lastPasteboardChange
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
        for t in [suggestTask, smartTask, addedTask, explainTask] { t?.cancel() }
        explainTask = nil
        explainPending = nil
        explainCache = [:]
        explainOffer = nil
        sharePrepared = nil
        shareAttempt = nil
        narration = nil
        notes = []
        notesOpen = false
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
        closeExplain()
        resetWriting()
        if case .working = bar { bar = .idle }
    }

    // MARK: notes

    var typed: String { (host?.contextBeforeInput ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }

    func toggleNotes() {
        forgetIfAccountChanged()
        host?.playClick()
        writeOpen = false
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
        updateFixable()
        scheduleWordSlots()
        if let u = undo, !(host?.contextBeforeInput ?? "").hasSuffix(u.replacement) { undo = nil }
        // The dictionary needs no pairing and no network, so a meaning shows even before pairing.
        if !paired, suggestsWhileTyping { _ = updateExplain(typed) }
        guard paired, suggestsWhileTyping else { return }
        if case .working = bar { return }
        let text = typed
        // An explain question is answered by the dictionary or /v1/explain, so it never also goes to /v1/suggest.
        let explaining = updateExplain(text)
        let wasEmpty = fieldEmpty
        fieldEmpty = text.isEmpty
        // Empty again, as after a send: the ready chips read the app's latest snapshot.
        if text.isEmpty, !wasEmpty { reloadSnapshot() }
        let clear = detectSmart(text)
        guard text != lastSent else { return }
        suggestTask?.cancel()
        lastSent = text
        bar = .idle
        if !explaining, let sentence = suggest.maybe(text, clear: clear) { requestSuggest(sentence, typed: text) }
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

    /// On every pause, on the phone: events, reminders and notes in the typed text. True when something clear was found.
    private func detectSmart(_ text: String) -> Bool {
        smartTask?.cancel()
        if text.isEmpty { smart = []; smartDone = []; serverSmart = nil; return false }
        let found = SmartDetect.detect(text, now: deps.now())
        let kept = serverSmart.flatMap { s in SuggestPolicy.sentenceKey(SmartDetect.lastSentence(text)) == s.sentence ? s.chips : nil } ?? []
        let shown = Array((found + kept.filter { k in !found.contains { $0.id == k.id } }).filter { !smartDone.contains($0) }.prefix(SmartDetect.maxChips))
        guard shown != smart else { return !found.isEmpty }
        let sleep = deps.sleep
        smartTask = Task { [weak self] in
            try? await sleep(SuggestPolicy.debounce)
            guard let self, !Task.isCancelled else { return }
            self.smart = shown
            self.recordCaught(shown)
        }
        return !found.isEmpty
    }

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
            let more = device.compactMap { Self.smartChip($0, sentence: sentence, now: self.deps.now()) }.filter { !self.smartDone.contains($0) }
            self.serverSmart = (SuggestPolicy.sentenceKey(sentence), more)
            self.smart = Array((self.smart + more.filter { m in !self.smart.contains { $0.id == m.id } }).prefix(SmartDetect.maxChips))
            let ms = Int((ContinuousClock.now - typedAt) / .milliseconds(1))
            self.lastLatencyMs = ms
            self.log.notice("PIP_TIMING keystroke_to_chip_ms=\(ms, privacy: .public) chips=\(more.count, privacy: .public) server_ms=\(res.timings?["total_ms"] ?? -1, privacy: .public)")
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
    private func updateFixable() {
        fixTask?.cancel()
        let d = draft
        guard paired, d.text != lastFixed, d.text.split(separator: " ").count >= 3 else { fixPlan = nil; return }
        let sleep = deps.slotSleep
        let skipLast = d.original.last?.isLetter ?? false
        fixTask = Task { [weak self] in
            try? await sleep(Self.slotDelay)
            guard !Task.isCancelled else { return }
            let plan = await Task.detached(priority: .userInitiated) { FixCheck.plan(d.text, skipLast: skipLast) }.value
            guard let self, !Task.isCancelled, self.draft == d else { return }
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

    private func apply(_ p: WritePreview, label: String) {
        guard replace(p.original, with: p.text) else { bar = .error("The text changed. Try again."); return }
        lastFixed = p.text
        fixPlan = nil
        bar = .idle
        lastWrite = p.kind
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
            apply(WritePreview(kind: "fix", title: plan.title, original: d.original, text: plan.fixed), label: plan.done)
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
                    self.apply(WritePreview(kind: "fix", title: "Fix grammar", original: d.original, text: res.text), label: "Fixed grammar \u{2713}")
                }
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.bar = .error("Could not fix that. Try again.")
            }
        }
    }

    func toggleWrite() {
        host?.playClick()
        notesOpen = false
        writeTask?.cancel()
        writePanel = .menu
        writeOpen.toggle()
    }

    var canWrite: Bool { !draft.text.isEmpty }

    func refine(_ tone: RefineTone) {
        let d = draft
        guard !d.text.isEmpty else { return }
        runPanel("Writing\u{2026}") { api in
            let res = try await api.refine(d.text, tone: tone.rawValue)
            return .preview(WritePreview(kind: "refine", title: tone.title, original: d.original, text: res.text))
        }
    }

    /// Tap on Fix grammar in the Rewrite panel: the server fixes grammar and spelling, and the result shows first.
    func fixGrammar() {
        let d = draft
        guard !d.text.isEmpty else { return }
        runPanel("Checking the grammar\u{2026}") { api in
            let res = try await api.fix(d.text)
            guard res.text != d.text else { return .message("The grammar looks good \u{2713}") }
            return .preview(WritePreview(kind: "fix", title: "Fix grammar", original: d.original, text: res.text))
        }
    }

    private func runPanel(_ label: String, _ work: @escaping (KeyboardAPI) async throws -> WritePanel) {
        host?.playClick()
        writeTask?.cancel()
        writePanel = .busy(label)
        writeTask = Task { [weak self] in
            do {
                guard let api = self?.deps.api() else { return }
                let next = try await work(api)
                guard let self, !Task.isCancelled else { return }
                self.writePanel = next
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.writePanel = .message("That did not work. Try again.")
            }
        }
    }

    func backToWriteMenu() {
        host?.playClick()
        writeTask?.cancel()
        writePanel = .menu
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
        writePanel = .preview(p)
        writeOpen = true
    }

    /// A clean slate: between intro scenes, and when the keyboard goes away.
    func resetWriting() {
        writeTask?.cancel()
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
                                    now: deps.now()))
    }

    func perform(_ action: BarItems.Action) {
        switch action {
        case .useCopied: useCopied()
        case .undo: undoWrite()
        case .openCalm: openCalmOffer()
        case .smart(let chip): tapSmart(chip)
        case .undoSmart: undoSmart()
        case .today: showToday()
        case .notes: toggleNotes()
        case .explain: openExplainCard()
        }
    }

    // MARK: smart chips (on the phone, no server)

    /// One tap adds it: the chip is the confirm. The bar then shows what was added, with Undo for a few seconds.
    func tapSmart(_ chip: SmartChip) {
        guard deps.writer.access(chip.place, hasFullAccess: hasFullAccess) == .ready else { return }
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
        smart.removeAll { $0 == chip }
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
        smartDone.remove(a.chip)
        if !smart.contains(a.chip) { smart.insert(a.chip, at: 0) }
    }

    /// "9:20 Dentist · 11:00 Lunch with Ana", from the snapshot the app wrote.
    private func showToday() {
        bar = .done(appointments.isEmpty ? "Nothing on your calendar today" : appointments.map { "\($0.time) \($0.title)" }.joined(separator: " \u{00B7} "))
    }
}
