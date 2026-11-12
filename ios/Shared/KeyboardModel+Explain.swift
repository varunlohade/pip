import Foundation

/// What the bar offers for an explain question: a dictionary meaning (on the phone) or the server's answer.
enum ExplainOffer: Equatable {
    case meaning(Meaning)
    case answer(subject: String, ExplainResponse)
    /// A graph or chart. `scene` is built on the phone; nil means the server draws it from `question`.
    case chart(subject: String, scene: Data?, question: String)

    var subject: String {
        switch self {
        case .meaning(let m): m.term
        case .answer(let s, _): s
        case .chart(let s, _, _): s
        }
    }

    var learnedKind: Learned.Kind {
        switch self {
        case .meaning: .word
        case .answer: .answer
        case .chart: .chart
        }
    }

    /// The one line the bar shows and Insert types.
    var line: String {
        switch self {
        case .meaning(let m): m.meaning
        case .answer(_, let r): r.short
        case .chart(let s, _, _): s
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
    /// Export was tapped: the row offers Send as image and Send as link.
    var exporting = false
    /// "Play with voice" is on: each step's line is spoken while it draws.
    var voice = false

    enum Tool: String, Equatable { case hand, draw, eraser }
    /// A short line after a send, such as "Copied. Tap the message box and Paste, then send."
    var note: String?
    /// Which send asked the page for its PNG.
    var sending: Send?

    enum Send: Equatable { case image, link }
}

enum ExplainPanel: Equatable {
    case card(ExplainOffer)
    case visual(VisualState)
}

/// The tldraw page in the visual panel. VisualWebView is the real one.
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

    private func clearExplainOffer() {
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

    var explainItem: BarItems.Item? {
        guard let o = explainOffer else { return nil }
        if case .chart = o { return BarItems.Item(id: "explain", title: "Draw it", action: .explain, trigger: o.subject) }
        return BarItems.Item(id: "explain", title: o.line, action: .explain, trigger: o.subject)
    }

    var visualOpen: Bool { if case .visual = explainPanel { return true }; return false }

    /// The keyboard grows while the visual panel is open, so the drawing has room.
    var keyboardHeight: CGFloat { visualOpen ? Theme.SystemKeyboard.visualHeight : Theme.SystemKeyboard.height }

    func openExplainCard() {
        guard let o = explainOffer else { return }
        host?.playClick()
        notesOpen = false
        writeOpen = false
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
        if case .chart = explainOffer { return false }
        return explainOffer != nil
    }

    /// The sky chip: a meaning or an answer goes straight into the message, like a suggestion; a chart opens its drawing.
    func tapExplainChip() {
        guard let o = explainOffer else { return }
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
    func visualFailed(_ message: String) {
        updateVisual { v in
            if case .loading = v.status { v.status = .failed("Could not draw that. Try again.") } else { v.note = "That did not work. Try again." }
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

    func toggleExport() {
        host?.playClick()
        updateVisual { $0.exporting.toggle(); $0.note = nil }
    }

    static let needsFullAccessToSend = "Turn on Full Access to send drawings"
    static let pasteHint = "Copied. Tap the message box and Paste, then send."

    /// Send as image or as link. A keyboard cannot attach a file, so the image goes to the pasteboard
    /// and the link goes into the message. Both need Full Access (pasteboard, App Group, network).
    func sendVisual(_ kind: VisualState.Send) {
        host?.playClick()
        guard hasFullAccess else { updateVisual { $0.note = Self.needsFullAccessToSend }; return }
        updateVisual { $0.sending = kind; $0.exporting = false; $0.note = kind == .image ? "Making the image\u{2026}" : "Making the link\u{2026}" }
        visualPage?.exportPNG()
    }

    /// The page's PNG for the send that asked for it. Every send also keeps the drawing in "your drawings".
    func visualExported(_ png: Data) {
        guard case .visual(let v) = explainPanel, let kind = v.sending else { return }
        try? deps.store.saveDrawing(png, title: v.subject, scene: v.scene)
        switch kind {
        case .image:
            deps.pasteboard.setPNG(png)
            updateVisual { $0.sending = nil; $0.note = Self.pasteHint }
        case .link:
            visualTask?.cancel()
            visualTask = Task { [weak self] in
                do {
                    guard let api = self?.deps.api() else { return }
                    let url = try await api.shareDrawing(png)
                    guard let self, !Task.isCancelled else { return }
                    let before = self.host?.contextBeforeInput ?? ""
                    self.host?.insert((before.isEmpty || before.last?.isWhitespace == true ? "" : " ") + url)
                    self.updateVisual { $0.sending = nil; $0.note = "Link added. Tap send." }
                } catch {
                    guard let self, !Task.isCancelled else { return }
                    self.updateVisual { $0.sending = nil; $0.note = "Could not make a link. Try Send as image." }
                }
            }
        }
    }

    private func updateVisual(_ change: (inout VisualState) -> Void) {
        guard case .visual(var v) = explainPanel else { return }
        change(&v)
        explainPanel = .visual(v)
    }
}
