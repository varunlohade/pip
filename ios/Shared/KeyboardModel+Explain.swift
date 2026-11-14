import Foundation

/// What the bar offers for an explain question: a dictionary meaning (on the phone) or the server's answer.
enum ExplainOffer: Equatable {
    case meaning(Meaning)
    case answer(subject: String, ExplainResponse)
    /// A graph or chart. `scene` is built on the phone; nil means the server draws it from `question`.
    case chart(subject: String, scene: Data?, question: String)
    /// A sum or a conversion, worked out on the phone. A tap types the answer in place of the ask.
    case calc(Calc.Answer)

    var subject: String {
        switch self {
        case .meaning(let m): m.term
        case .answer(let s, _): s
        case .chart(let s, _, _): s
        case .calc(let a): a.trigger
        }
    }

    var learnedKind: Learned.Kind {
        switch self {
        case .meaning: .word
        case .answer, .calc: .answer
        case .chart: .chart
        }
    }

    /// The one line the bar shows and Insert types.
    var line: String {
        switch self {
        case .meaning(let m): m.meaning
        case .answer(_, let r): r.short
        case .chart(let s, _, _): s
        case .calc(let a): a.title
        }
    }
}

/// The visual panel: the topic, the scene once it came, and where the drawing is.
struct VisualState: Equatable {
    enum Status: Equatable { case loading, drawing(step: Int, of: Int), done(steps: Int), failed(String) }
    let subject: String
    /// The one-line answer, for Insert.
    let summary: String
    var status: Status = .loading
    var scene: Data?
    /// What the finger does on the canvas: move it, draw on it, or erase.
    var tool: Tool = .hand
    /// What the step being drawn says, shown under the canvas.
    var say: String?
    /// The small menu next to Send is open: it offers Send as image.
    var exporting = false
    /// "Play with voice" is on: each step's line is spoken while it draws.
    var voice = false

    enum Tool: String, Equatable { case hand, draw, eraser }
    /// A short line after a send, such as "Link added. Tap send."
    var note: String?
    /// A quieter second line under the note, such as "Image also copied".
    var hint: String?
    /// Which send asked the page for its PNG. `prepare` is the export when the drawing finishes; it stays on the phone.
    var sending: Send?

    enum Send: Equatable { case image, link, prepare }
}

enum ExplainPanel: Equatable {
    case card(ExplainOffer)
    case visual(VisualState)
}

/// The drawing page in the visual panel. VisualWebView is the real one.
@MainActor
protocol VisualPage: AnyObject {
    func play(_ scene: Data)
    func replay()
    func setTool(_ tool: VisualState.Tool)
    func undo()
    func redo()
    func exportPNG()
    /// With voice on, the page waits after each step until next().
    func setVoice(_ on: Bool)
    func next()
}

extension KeyboardModel {
    /// A paid answer waits for a longer pause than the free suggestions, so a half-typed topic is not sent.
    static let explainDebounce: Duration = .milliseconds(700)

    /// On every edit: the dictionary answers a term at once; a topic or a dictionary miss goes to /v1/explain after a pause.
    /// True when the sentence is an explain question.
    @discardableResult
    func updateExplain(_ text: String) -> Bool {
        if let chart = Chart.detect(text) {
            explainTask?.cancel()
            explainPending = nil
            let offer = Self.chartOffer(chart)
            if explainOffer != offer { explainOffer = offer }
            return true
        }
        if let (ask, trigger) = Calc.read(text) {
            explainTask?.cancel()
            explainPending = nil
            if ask.needsRates { refreshRates() }
            let offer = Calc.answer(ask, trigger: trigger, now: deps.now(), zone: .current, rates: currencyRates).map(ExplainOffer.calc)
            if explainOffer != offer { explainOffer = offer }
            return true
        }
        guard let ask = Explain.detect(text) else { clearExplainOffer(); return false }
        if ask.kind == .term, let m = ExplainDictionary.shared.lookup(ask.subject) {
            explainTask?.cancel()
            explainPending = nil
            if explainOffer != .meaning(m) { explainOffer = .meaning(m) }
            return true
        }
        let key = ask.question.lowercased()
        if case .answer(let s, _)? = explainOffer, s == ask.subject { return true }
        explainOffer = nil
        if let r = explainCache[key] { explainOffer = .answer(subject: ask.subject, r); return true }
        guard paired, ask.kind == .topic || ask.askServerOnMiss, SecretScan.scan(ask.question) == .clean else { return true }
        guard explainPending != key else { return true }
        explainTask?.cancel()
        explainPending = key
        let sleep = deps.sleep
        explainTask = Task { [weak self] in
            try? await sleep(Self.explainDebounce)
            guard let self, !Task.isCancelled else { return }
            let res = try? await self.deps.api().explain(ask.question)
            guard !Task.isCancelled, self.explainPending == key else { return }
            self.explainPending = nil
            guard let res else { return }
            self.explainCache[key] = res
            // Only while the field still asks the same thing.
            guard Explain.detect(self.typed)?.subject == ask.subject else { return }
            self.explainOffer = .answer(subject: ask.subject, res)
        }
        return true
    }

    func clearExplainOffer() {
        explainTask?.cancel()
        explainPending = nil
        if explainOffer != nil { explainOffer = nil }
    }

    /// A chart offer: the subject the bar quotes and, when the phone could read the data, the scene.
    static func chartOffer(_ c: Chart.Request) -> ExplainOffer {
        switch c {
        case .function(_, let text): .chart(subject: "y = \(text)", scene: ChartScene.build(c)?.json(), question: "graph y = \(text)")
        case .data(let kind, let title, let items):
            .chart(subject: title ?? "\(kind.rawValue) chart", scene: ChartScene.build(c)?.json(),
                   question: items.map { "\($0.label) \(ChartScene.format($0.value))" }.joined(separator: ", "))
        case .unclear(let q): .chart(subject: "chart", scene: nil, question: q)
        }
    }

    /// The last rates, from memory after the first read.
    private var currencyRates: Calc.Rates? {
        if let kept = ratesKept { return kept }
        let r = deps.store.currencyRates
        ratesKept = .some(r)
        return r
    }

    /// Currency rates at most once an hour from /v1/rates; the last ones stay on the phone for offline use.
    /// A failed read waits a few minutes before the next try.
    private func refreshRates() {
        let now = deps.now()
        if let r = currencyRates, now.timeIntervalSince(r.fetched_at) < 3600 { return }
        guard paired, hasFullAccess, ratesTask == nil, ratesAskedAt.map({ now.timeIntervalSince($0) > 300 }) ?? true else { return }
        ratesAskedAt = now
        let api = deps.api()
        ratesTask = Task { [weak self] in
            let r = try? await api.rates()
            guard let self else { return }
            self.ratesTask = nil
            guard let r, !Task.isCancelled else { return }
            self.deps.store.currencyRates = r
            self.ratesKept = r
            // The chip waited for the rates; it shows while the field still asks.
            if Calc.read(self.typed)?.ask.needsRates == true { self.updateExplain(self.typed) }
        }
    }

    /// The answer replaces the ask ("split 120 4 ways" becomes "$30.00 each"); a sum keeps its working ("12*7 = 84").
    private func insertCalc(_ a: Calc.Answer) {
        host?.playClick()
        let before = host?.contextBeforeInput ?? ""
        let sentence = SmartDetect.lastSentence(before)
        if !sentence.isEmpty, let r = before.range(of: sentence, options: .backwards) {
            for _ in 0..<before.distance(from: r.lowerBound, to: before.endIndex) { host?.deleteBackward() }
        }
        host?.insert(a.insert)
        explainOffer = nil
        updateAutoShift()
    }

    var explainItem: BarItems.Item? {
        guard let o = explainOffer else { return nil }
        if case .calc(let a) = o { return BarItems.Item(id: "explain", title: a.title, detail: a.note, action: .explain, trigger: a.trigger) }
        if case .chart = o { return BarItems.Item(id: "explain", title: "Draw it", action: .explain, trigger: o.subject) }
        return BarItems.Item(id: "explain", title: o.line, action: .explain, trigger: o.subject)
    }

    /// The offer read again from the text at tap time. A chip the text no longer asks for does nothing and goes.
    private func currentExplainOffer() -> ExplainOffer? {
        guard let shown = explainOffer else { return nil }
        updateExplain(typed)
        guard let now = explainOffer, now.subject == shown.subject, now.learnedKind == shown.learnedKind else { return nil }
        return now
    }

    var visualOpen: Bool { if case .visual = explainPanel { return true }; return false }

    /// The keyboard grows while the visual panel or the calendar is open, so they have room.
    var keyboardHeight: CGFloat { Self.height(panel: explainPanel, calendarOpen: calendar != nil || payPanel != nil) }

    static func height(panel: ExplainPanel?, calendarOpen: Bool) -> CGFloat {
        if case .visual? = panel { return Theme.SystemKeyboard.visualHeight }
        return calendarOpen ? Theme.SystemKeyboard.calendarHeight : Theme.SystemKeyboard.height
    }

    func openExplainCard() {
        guard let o = currentExplainOffer() else { return }
        if case .calc(let a) = o { insertCalc(a); return }
        host?.playClick()
        notesOpen = false
        writeOpen = false
        closeCalendar()
        deps.store.recordLearned(Learned(subject: o.subject, line: o.line, kind: o.learnedKind, date: deps.now()))
        if case .chart(let subject, let scene, let question) = o {
            // Insert types "y = x^2" for a graph, or the data for a chart.
            openVisual(subject: subject, summary: question.hasPrefix("graph ") ? subject : question, scene: scene, ask: question)
        } else {
            explainPanel = .card(o)
        }
    }

    /// A meaning or answer has a card with more; a chart opens its drawing straight away.
    var explainOfferHasMore: Bool {
        switch explainOffer { case .chart, .calc: return false; default: break }
        return explainOffer != nil
    }

    /// The sky chip: a meaning or an answer goes straight into the message, like a suggestion; a chart opens its drawing.
    func tapExplainChip() {
        guard let o = currentExplainOffer() else { return }
        if case .calc(let a) = o { insertCalc(a); return }
        if case .chart = o { openExplainCard(); return }
        deps.store.recordLearned(Learned(subject: o.subject, line: o.line, kind: o.learnedKind, date: deps.now()))
        explainPanel = .card(o)
        insertExplain()
    }

    func closeExplain() {
        stopVoice()
        visualTask?.cancel()
        explainPanel = nil
    }

    /// Insert on the card or the visual panel: the one-line answer goes into the message.
    func insertExplain() {
        let line: String
        switch explainPanel {
        case .card(let o): line = o.line
        case .visual(let v): line = v.summary
        case nil: return
        }
        host?.playClick()
        let before = host?.contextBeforeInput ?? ""
        host?.insert((before.isEmpty || before.last?.isWhitespace == true ? "" : " ") + line)
        closeExplain()
        explainOffer = nil
        updateAutoShift()
    }

    /// "Show visually": the panel opens at once and the scene comes from /v1/explain/visual.
    func showVisual() {
        guard case .card(let o) = explainPanel else { return }
        host?.playClick()
        openVisual(subject: o.subject, summary: o.line, scene: nil, ask: o.subject)
    }

    /// The visual panel with a scene in hand (a chart read on the phone), or one the server draws for `ask`.
    private func openVisual(subject: String, summary: String, scene: Data?, ask topic: String) {
        explainPanel = .visual(VisualState(subject: subject, summary: summary, scene: scene))
        visualTask?.cancel()
        sharePrepared = nil
        shareAttempt = nil
        if let scene { visualPage?.play(scene); return }
        visualTask = Task { [weak self] in
            do {
                guard let api = self?.deps.api() else { return }
                let scene = try await api.explainVisual(topic)
                guard let self, !Task.isCancelled else { return }
                self.updateVisual { $0.scene = scene }
                self.visualPage?.play(scene)
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.updateVisual { $0.status = .failed("Could not draw that. Try again.") }
            }
        }
    }

    /// The page loaded (or came back): it gets the scene if one is waiting.
    func visualPageReady(_ page: VisualPage) {
        visualPage = page
        if case .visual(let v) = explainPanel, let scene = v.scene { page.play(scene) }
    }

    func visualStep(_ n: Int, of m: Int, say: String? = nil) {
        updateVisual { $0.status = .drawing(step: n, of: m); $0.say = say }
        narration?.stepStarted(n, say: say)
    }
    func visualStepDrawn(_ n: Int) { narration?.stepDrawn(n) }
    func visualDone() {
        updateVisual { if case .drawing(_, let m) = $0.status { $0.status = .done(steps: m) } else { $0.status = .done(steps: 1) } }
        // The last line may still be speaking; it ends on its own, and the button goes back to "Play with voice".
        if narration != nil { narration = nil; visualPage?.setVoice(false); updateVisual { $0.voice = false } }
        prepareShare()
    }

    /// "Play with voice": only this tap ever starts sound. It replays the drawing with each step's line spoken in time;
    /// a second tap stops the voice at once. The audio is "ambient", so the silent switch mutes it.
    func toggleVoice() {
        host?.playClick()
        guard case .visual(let v) = explainPanel else { return }
        if v.voice { stopVoice(); return }
        let sync = NarrationSync(speaker: deps.speaker(), sleep: deps.sleep) { [weak self] in self?.visualPage?.next() }
        narration = sync
        updateVisual { $0.voice = true; $0.note = "Turn the ringer on to hear Pip" }
        visualPage?.setVoice(true)
        visualPage?.replay()
    }

    private func stopVoice() {
        guard let n = narration else { return }
        narration = nil
        n.stop()
        visualPage?.setVoice(false)
        updateVisual { $0.voice = false; $0.note = nil }
    }
    /// Before the drawing shows, the panel says it failed; after, a failed export is only a note, and the drawing stays.
    /// A failed export made ahead of Send says nothing; Send exports again.
    func visualFailed(_ message: String) {
        updateVisual { v in
            if case .loading = v.status { v.status = .failed("Could not draw that. Try again.") }
            else if v.sending != .prepare { v.note = "That did not work. Try again."; v.hint = nil }
            v.sending = nil
        }
    }

    func replayVisual() {
        host?.playClick()
        visualPage?.replay()
    }

    /// The canvas tools: tap a tool to use it, tap it again to go back to moving the canvas.
    func selectVisualTool(_ tool: VisualState.Tool) {
        host?.playClick()
        updateVisual { $0.tool = $0.tool == tool ? .hand : tool }
        if case .visual(let v) = explainPanel { visualPage?.setTool(v.tool) }
    }

    func undoVisual() {
        host?.playClick()
        visualPage?.undo()
    }

    func redoVisual() {
        host?.playClick()
        visualPage?.redo()
    }

    /// The small menu next to Send: it opens and closes "Send as image".
    func toggleExport() {
        host?.playClick()
        updateVisual { $0.exporting.toggle(); $0.note = nil; $0.hint = nil }
    }

    static let needsFullAccessToSend = "Turn on Full Access to send drawings"
    static let pasteHint = "Copied. Tap the message box and Paste, then send."
    static let linkAdded = "Link added. Tap send."
    static let imageAlsoCopied = "Image also copied"
    static let sendingNote = "Sending\u{2026}"
    /// How long Send waits for the upload before it falls back to the copied image.
    static let shareWait: Duration = .seconds(5)

    /// The line typed before the link, such as "y = log(x), explained:".
    static func shareCaption(_ subject: String) -> String { "\(subject), explained:" }

    /// Send (one tap): the drawing uploads, then the caption and the short link take the place of the typed request.
    /// The PNG goes to the pasteboard at once as a fallback. The link opens a page whose preview shows the picture in the chat.
    /// Send as image (in the small menu) only copies the PNG. A keyboard cannot attach a file.
    /// Both need Full Access (pasteboard, App Group, network). Nothing leaves the phone before the tap.
    func sendVisual(_ kind: VisualState.Send) {
        host?.playClick()
        guard hasFullAccess else { updateVisual { $0.note = Self.needsFullAccessToSend; $0.hint = nil }; return }
        updateVisual { $0.sending = kind; $0.exporting = false; $0.note = kind == .image ? "Making the image\u{2026}" : nil; $0.hint = nil }
        visualPage?.exportPNG()
    }

    /// When the drawing finishes, its PNG and JPEG preview are made on the phone, so Send only uploads.
    private func prepareShare() {
        guard hasFullAccess, case .visual(let v) = explainPanel, v.sending == nil else { return }
        updateVisual { $0.sending = .prepare }
        visualPage?.exportPNG()
    }

    /// The page's PNG for the export that asked for it. Every send also keeps the drawing in "your drawings".
    func visualExported(_ png: Data) {
        guard case .visual(let v) = explainPanel, let kind = v.sending else { return }
        if kind == .prepare {
            updateVisual { $0.sending = nil }
            if sharePrepared?.png != png { sharePrepared = (png, LinkPreview.jpeg(png)) }
            return
        }
        try? deps.store.saveDrawing(png, title: v.subject, scene: v.scene)
        deps.pasteboard.setPNG(png)
        if kind == .image {
            updateVisual { $0.sending = nil; $0.note = Self.pasteHint; $0.hint = nil }
            return
        }
        // Send exports again, so a drawing changed with the pen after it finished gets a new preview.
        if sharePrepared?.png != png { sharePrepared = (png, LinkPreview.jpeg(png)) }
        let preview = sharePrepared?.preview
        let attempt = UUID()
        shareAttempt = attempt
        updateVisual { $0.note = Self.sendingNote }
        // Whichever comes first: the link, or five seconds, after which the copied image is the way to send.
        // Awaiting an upload cannot be cancelled, so the two waits are separate tasks and the first one ends the send.
        let api = deps.api()
        Task { [weak self] in
            let url = try? await api.shareDrawing(png, preview: preview, title: v.subject)
            self?.finishShare(attempt, url: url, subject: v.subject)
        }
        visualTask?.cancel()
        let sleep = deps.sleep
        visualTask = Task { [weak self] in
            try? await sleep(Self.shareWait)
            guard let self, !Task.isCancelled else { return }
            self.finishShare(attempt, url: nil, subject: v.subject)
        }
    }

    /// Ends the Send that is waiting: the caption and link on success, else the copied-image hint.
    private func finishShare(_ attempt: UUID, url: String?, subject: String) {
        guard shareAttempt == attempt, case .visual(let v) = explainPanel, v.sending == .link else { return }
        shareAttempt = nil
        if let url { insertShareLink(url, subject: subject) }
        else { updateVisual { $0.sending = nil; $0.note = Self.pasteHint; $0.hint = nil } }
    }

    /// The caption and link replace the request that opened the drawing ("explain log function"), so nothing repeats.
    /// Text typed before the request stays. When the request is no longer the last sentence, the link goes after the text.
    private func insertShareLink(_ url: String, subject: String) {
        var before = host?.contextBeforeInput ?? ""
        let sentence = SmartDetect.lastSentence(before)
        if !sentence.isEmpty, Self.requestSubject(before) == subject, let r = before.range(of: sentence, options: .backwards) {
            let drop = before.distance(from: r.lowerBound, to: before.endIndex)
            for _ in 0..<drop { host?.deleteBackward() }
            before.removeSubrange(r.lowerBound...)
        }
        host?.insert((before.isEmpty || before.last?.isWhitespace == true ? "" : " ") + Self.shareCaption(subject) + " " + url)
        updateVisual { $0.sending = nil; $0.note = Self.linkAdded; $0.hint = Self.imageAlsoCopied }
        updateAutoShift()
    }

    /// The subject the last sentence asks to draw or explain, as the visual panel names it.
    private static func requestSubject(_ text: String) -> String? {
        if let chart = Chart.detect(text) { return chartOffer(chart).subject }
        return Explain.detect(text)?.subject
    }

    private func updateVisual(_ change: (inout VisualState) -> Void) {
        guard case .visual(var v) = explainPanel else { return }
        change(&v)
        explainPanel = .visual(v)
    }
}
