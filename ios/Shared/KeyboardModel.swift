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
    func insert(_ text: String)
    func deleteBackward()
    func nextKeyboard()
    func playClick()
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
    /// The explain card or the visual panel, in place of the keys. Nil when the keys show.
    @Published var explainPanel: ExplainPanel?
    // Explain state, kept here because extensions cannot hold stored properties.
    var explainTask: Task<Void, Never>?
    var visualTask: Task<Void, Never>?
    /// The question the server is answering now, so one pause sends it once.
    var explainPending: String?
    var explainCache: [String: ExplainResponse] = [:]
    var ratesTask: Task<Void, Never>?
    /// When the keyboard last asked for currency rates, so a currency ask reads them at most every few minutes.
    var ratesAskedAt: Date?
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
    private var rewriteTasks: [Task<Void, Never>] = []
    /// A version with no answer by then shows Retry. The whole list gives up at the timeout.
    static let rewriteStall: Duration = .seconds(4)
    static let rewriteTimeout: Duration = .seconds(8)
    static var rewriteFailed: String { "Couldn't reach \(AppConfig.displayName). Tap Retry." }
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
    }

    // MARK: keys (touch model of the system keyboard)

    private var active: [ObjectIdentifier: KeyCap] = [:]
    private var lastShiftTap: Date?
    private var lastSpaceTap: Date?
    private var deleteTask: Task<Void, Never>?

    func display(_ c: String) -> String { layout == .letters && shift != .off ? c.uppercased() : c }

    func touchBegan(_ id: ObjectIdentifier, _ key: KeyCap) {
        host?.playClick()
        // A new touch commits any letter still held by another finger, like iOS.
        for (other, k) in active where other != id { if case .char = k.kind { commit(k); release(other) } }
        active[id] = key
        pressedKeys.insert(key.id)
        if case .char = key.kind { calloutKeyID = key.id }
        if key.kind == .delete { deleteDown() }
    }

    func touchMoved(_ id: ObjectIdentifier, _ key: KeyCap) {
        guard let current = active[id], current.id != key.id, case .char = current.kind, case .char = key.kind else { return }
        pressedKeys.remove(current.id)
        active[id] = key
        pressedKeys.insert(key.id)
        calloutKeyID = key.id
    }

    func touchEnded(_ id: ObjectIdentifier) {
        guard let key = active[id] else { return }
        release(id)
        if key.kind == .delete { deleteTask?.cancel(); return }
        commit(key)
    }

    func touchCancelled(_ id: ObjectIdentifier) {
        if active[id]?.kind == .delete { deleteTask?.cancel() }
        release(id)
    }

    /// VoiceOver activation and tests without touches.
    func activate(_ key: KeyCap) {
        host?.playClick()
        if key.kind == .delete { host?.deleteBackward(); afterEdit(); return }
        commit(key)
    }

    private func release(_ id: ObjectIdentifier) {
        if let k = active.removeValue(forKey: id) {
            pressedKeys.remove(k.id)
            if calloutKeyID == k.id { calloutKeyID = nil }
        }
    }

    private func commit(_ key: KeyCap) {
        switch key.kind {
        case .char(let c):
            host?.insert(display(c))
            if shift == .once && layout == .letters { shift = .off }
            if layout != .letters && c == "'" { layout = .letters }
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
            tapSpace()
        case .ret:
            if expandShortcut() { break }
            host?.insert("\n")
            lastSpaceTap = nil
            afterEdit()
        case .globe:
            host?.nextKeyboard()
        case .delete:
            break
        }
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

    /// Delete fires on touch down, repeats after 0.5 s, then speeds up to whole words.
    private func deleteDown() {
        host?.deleteBackward()
        afterEdit()
        deleteTask?.cancel()
        let sleep = deps.sleep
        deleteTask = Task { [weak self] in
            try? await sleep(.milliseconds(500))
            var n = 0
            while !Task.isCancelled, let self {
                if n < 20 { self.host?.deleteBackward() } else { self.deleteWord() }
                self.afterEdit()
                n += 1
                try? await sleep(.milliseconds(n < 20 ? 100 : 250))
            }
        }
    }

    private func deleteWord() {
        let before = host?.contextBeforeInput ?? ""
        var count = 0
        var seenWord = false
        for ch in before.reversed() {
            if ch.isWhitespace { if seenWord { break } } else { seenWord = true }
            count += 1
        }
        for _ in 0..<max(count, 1) { host?.deleteBackward() }
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
        layout = .letters
        updateAutoShift()
        guard hasFullAccess else { copiedAvailable = false; return }
        deps.store.keyboardLastSeen = deps.now()
        reloadShortcuts()
        guard paired else { return }
        reloadSnapshot()
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
        for t in [suggestTask, smartTask, addedTask, explainTask, fixTask, copiedTask] { t?.cancel() }
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
        let text = typed
        typedPast(text)
        let quiet = chipsQuiet(text)
        updateFixable(quiet: quiet)
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
        guard text != lastSent else { return }
        suggestTask?.cancel()
        lastSent = text
        bar = .idle
        // Typing ends the copied-text offer.
        if !text.isEmpty, copiedAvailable { endCopied() }
        if !quiet, !explaining, let sentence = suggest.maybe(text, clear: clear) { requestSuggest(sentence, typed: text) }
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
        let visible = !smart.isEmpty || explainOffer != nil
        if !visible { chipSeen = nil } else if chipSeen == nil { chipSeen = (deps.now(), ChipTiming.words(typed)) }
    }

    /// ✕ on the bar: every chip goes, none comes back for 10 s, and none while the text stays the same.
    func dismissChips() {
        host?.playClick()
        quietUntil = deps.now().addingTimeInterval(ChipTiming.dismissQuiet)
        dismissedText = typed
        if copiedAvailable { endCopied() }
        calmOffer = nil
        clearChips()
    }

    private func clearChips() {
        for t in [smartTask, fixTask, suggestTask] { t?.cancel() }
        if !smart.isEmpty { smart = [] }
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
        return Array((found + kept.filter { k in !found.contains { $0.id == k.id } }).filter { !smartDone.contains($0) }.prefix(SmartDetect.maxChips))
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
            self.serverSmart = (sentence, more)
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

    /// Fix leaves at once when the text is clean. Once shown it follows the text with no pause, so it never blinks.
    /// A new Fix waits for the fingers to settle: 0.4 s, or 1.0 s in the middle of a word.
    private func updateFixable(quiet: Bool = false) {
        fixTask?.cancel()
        let d = draft
        guard paired, !quiet, d.text != lastFixed, d.text.split(separator: " ").count >= 3, let plan = localFix(d) else { fixPlan = nil; return }
        if fixPlan != nil { if fixPlan != plan { fixPlan = plan }; return }
        let sleep = deps.sleep
        let wait = ChipTiming.settle(after: host?.contextBeforeInput ?? "")
        fixTask = Task { [weak self] in
            try? await sleep(wait)
            guard let self, !Task.isCancelled else { return }
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

    /// The Rewrite button: the panel opens and every version starts at once.
    func toggleWrite() {
        host?.playClick()
        notesOpen = false
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
            self.settleRewrites(asked, original: d.original)
        }
        batch.tasks = [stream, stall, timeout]
        rewriteTasks += batch.tasks
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
        rewriteTasks.forEach { $0.cancel() }
        rewriteTasks = []
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
        // The tap reads the text again: a chip the text no longer holds does nothing and goes.
        let text = typed
        guard smartChips(text, found: SmartDetect.detect(text, now: deps.now())).contains(chip) else {
            smart.removeAll { $0 == chip }
            return
        }
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

/// Tasks that stop together: the stream, its stall timer and its timeout.
@MainActor
private final class TaskBatch {
    var tasks: [Task<Void, Never>] = []
    func cancel() { tasks.forEach { $0.cancel() } }
}
