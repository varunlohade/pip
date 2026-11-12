import XCTest
@testable import Pip

/// Explain detection on the phone, the bundled dictionary, and the keyboard flow with a fake server.
final class ExplainDetectTests: XCTestCase {
    private func term(_ text: String, _ subject: String, line: UInt = #line) {
        let a = Explain.detect(text)
        XCTAssertEqual(a?.kind, .term, text, line: line)
        XCTAssertEqual(a?.subject, subject, text, line: line)
    }

    private func topic(_ text: String, _ subject: String, line: UInt = #line) {
        let a = Explain.detect(text)
        XCTAssertEqual(a?.kind, .topic, text, line: line)
        XCTAssertEqual(a?.subject, subject, text, line: line)
    }

    func testTermQuestions() {
        term("what does btw mean", "btw")
        term("What does BTW mean?", "btw")
        term("what does \u{201C}no cap\u{201D} mean", "no cap")
        term("wait what does iykyk stand for", "iykyk")
        term("whats rizz", "rizz")
        term("what\u{2019}s fomo?", "fomo")
        term("btw meaning", "btw")
        term("meaning of tbh", "tbh")
        term("what's the meaning of situationship", "situationship")
        term("define apr", "apr")
        term("wdym delulu", "delulu")
        term("wdym by mid", "mid")
        term("lol ok. what does ngl mean", "ngl")
        term("hey pip, what does the word yeet mean", "yeet")
        term("see you at 5\nwhat does eta mean", "eta")
    }

    func testTopicQuestions() {
        topic("explain log function", "log function")
        topic("Explain log functions", "log functions")
        topic("can you explain compound interest?", "compound interest")
        topic("what is a log function", "log function")
        topic("what is an ion thruster", "ion thruster")
        topic("eli5 compound interest", "compound interest")
        topic("ELI5: inflation", "inflation")
        topic("explain like i'm 5 black holes", "black holes")
        topic("how does a vpn work", "vpn")
        topic("what is quantum computing", "quantum computing")
    }

    func testWhatIsATermTheDictionaryKnowsIsAnsweredOnThePhone() {
        term("what is compound interest", "compound interest")
        term("what is an index fund", "index fund")
    }

    func testPlainChatAndLookalikesAreNotQuestions() {
        for text in [
            "what does your mom think", "what does it mean", "what do you mean", "what does that mean?", "explain later",
            "I'll explain later", "explain it to me", "explain yourself", "can you explain this", "let me explain the plan",
            "what's up", "whats up bro", "what is going on", "what's for dinner", "what is your name", "what is happening",
            "what's the plan", "what is it", "what is wrong with you", "what's new", "what time is it", "lol ok see you",
            "i can do tuesday at 3", "dinner with Ana friday 7pm", "that means a lot", "no meaning", "it has no meaning",
            "how does that work", "how do you know", "explain", "what does", "meaning", "",
        ] {
            XCTAssertNil(Explain.detect(text), text)
        }
    }

    func testWeakFormAsksTheServerOnlyForOneWord() {
        XCTAssertEqual(Explain.detect("skibidoo meaning")?.askServerOnMiss, true)
        XCTAssertEqual(Explain.detect("life goals meaning")?.askServerOnMiss, false)
    }

    func testAQuestionTooLongIsNotSent() {
        XCTAssertNil(Explain.detect("explain " + String(repeating: "x", count: Explain.maxQuestion)))
    }
}

final class ExplainDictionaryTests: XCTestCase {
    func testBundledDictionaryLoadsAndAnswersCommonTerms() {
        let d = ExplainDictionary.shared
        XCTAssertGreaterThan(d.count, 1000)
        XCTAssertEqual(d.lookup("btw")?.meaning, "by the way")
        XCTAssertEqual(d.lookup("BTW")?.term, "btw")
        for t in ["idk", "imo", "tbh", "fomo", "no cap", "rizz", "lowkey", "apr", "e.g.", "eg", "tl;dr", "wdym"] {
            let m = d.lookup(t)
            XCTAssertNotNil(m, t)
            XCTAssertFalse(m?.meaning.isEmpty ?? true, t)
            XCTAssertFalse(m?.example.isEmpty ?? true, t)
        }
        XCTAssertNil(d.lookup("log function"))
    }

    func testEveryEntryIsShortAndClean() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "explain-dictionary", withExtension: "json"))
        let all = try JSONDecoder().decode([String: [String]].self, from: Data(contentsOf: url))
        let banned = ["fuck", "shit", "bitch", "porn", "sex", "nude", "cocaine", "weed"]
        for (k, v) in all {
            XCTAssertEqual(v.count, 2, k)
            XCTAssertEqual(k, k.lowercased(), k)
            XCTAssertLessThanOrEqual(v[0].count, 60, k)
            XCTAssertLessThanOrEqual(v[1].count, 80, k)
            let words = (k + " " + v.joined(separator: " ")).lowercased()
            XCTAssertFalse(banned.contains { words.contains($0) }, k)
        }
    }
}

@MainActor
final class ExplainModelTests: XCTestCase {
    private var host: FakeHost!
    private var api: FakeAPI!
    private var clock: FakeClock!
    private var store: FakeStore!
    private var pasteboard: FakePasteboard!
    private var model: KeyboardModel!

    override func setUp() async throws {
        host = FakeHost()
        api = FakeAPI()
        clock = FakeClock()
        store = FakeStore()
        pasteboard = FakePasteboard()
        model = KeyboardModel(deps: .fake(api: api, store: store, pasteboard: pasteboard, clock: clock))
        model.host = host
        model.keyboardAppeared()
    }

    private func set(_ text: String) {
        host.text = text
        model.textChanged()
    }

    private func until(_ what: String, _ cond: () -> Bool) async {
        for _ in 0..<500 where !cond() { await Task.yield() }
        XCTAssertTrue(cond(), "timed out waiting for \(what)")
    }

    private func pass(_ d: Duration) async {
        await until("a sleep") { clock.sleeping > 0 }
        clock.advance(d.seconds)
    }

    func testADictionaryTermShowsAtOnceWithNoServerCall() async {
        set("what does btw mean")
        let item = model.barItems.first
        XCTAssertEqual(item?.id, "explain")
        XCTAssertEqual(item?.trigger, "btw")
        XCTAssertEqual(item?.title, "by the way")
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(api.calls, [], "no explain and no suggest call")
    }

    func testSendingWithoutFullAccessExplainsWhy() async {
        set("explain log function")
        await pass(KeyboardModel.explainDebounce)
        await until("explain answer") { model.explainOffer != nil }
        model.perform(.explain)
        model.showVisual()
        host.hasFullAccess = false
        model.refreshAccess()
        model.sendVisual(.image)
        guard case .visual(let v)? = model.explainPanel else { return XCTFail("panel closed") }
        XCTAssertEqual(v.note, KeyboardModel.needsFullAccessToSend)
        model.sendVisual(.link)
        XCTAssertNil(pasteboard.png)
        XCTAssertFalse(api.calls.contains("share"))
    }

    func testAChartIsDrawnOnThePhoneWithNoServerCall() async {
        set("bar chart: rent 1200, food 400, fun 200")
        XCTAssertEqual(model.barItems.first?.trigger, "bar chart")
        XCTAssertEqual(model.barItems.first?.title, "Draw it")
        model.perform(.explain)
        guard case .visual(let v)? = model.explainPanel else { return XCTFail("no panel") }
        XCTAssertNotNil(v.scene)
        XCTAssertEqual(v.summary, "rent 1200, food 400, fun 200")
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(api.calls, [])
    }

    func testAGraphInsertsItsEquation() {
        set("graph y = x^2")
        model.perform(.explain)
        model.insertExplain()
        XCTAssertEqual(host.text, "graph y = x^2 y = x^2")
    }

    func testAnUnclearChartAsksTheServerToDrawIt() async {
        set("bar chart of my spending")
        model.perform(.explain)
        await until("visual call") { api.calls == ["visual"] }
        XCTAssertEqual(api.explained, ["bar chart of my spending"])
    }

    func testTheSkyChipTypesTheMeaningAndCountsAsLearned() {
        set("what does btw mean")
        XCTAssertTrue(model.explainOfferHasMore)
        model.tapExplainChip()
        XCTAssertEqual(host.text, "what does btw mean by the way")
        XCTAssertEqual(store.learned.map(\.subject), ["btw"])
        XCTAssertEqual(store.learned.first?.kind, .word)
        XCTAssertNil(model.explainPanel)
    }

    func testOpeningAChartCountsAsLearned() {
        set("graph y = x^2")
        XCTAssertFalse(model.explainOfferHasMore)
        model.tapExplainChip()
        XCTAssertTrue(model.visualOpen)
        XCTAssertEqual(store.learned.first?.kind, .chart)
    }

    func testPlansShownAsChipsAreKeptForHomeUntilAdded() async {
        set("dentist friday 10am")
        await until("smart sleep") { clock.sleeping > 0 }
        clock.advance(SuggestPolicy.debounce.seconds)
        await until("smart chip") { !model.smart.isEmpty }
        XCTAssertEqual(store.caught.map(\.place), [.calendar])
        XCTAssertEqual(store.caught.first?.title, "Dentist")
        model.tapSmart(model.smart[0])
        XCTAssertEqual(store.caught, [])
    }

    func testTheMeaningTakesTheBarFromTheDayChips() {
        let chip = BarItems.Item(id: "explain", title: "by the way", action: .explain, trigger: "btw")
        let next = Appointment(start: Date(), end: Date().addingTimeInterval(1800), title: "Team standup")
        let items = BarItems.build(.init(hasFullAccess: true, paired: true, undo: nil, hasCalmOffer: false, bar: .idle,
                                         copiedAvailable: true, nextUp: next, explain: chip))
        XCTAssertEqual(items.map(\.id), ["explain"])
    }

    func testTheMeaningShowsEvenWithoutPairing() {
        store.deviceToken = nil
        model.keyboardAppeared()
        set("what does tbh mean")
        XCTAssertEqual(model.barItems.map(\.id), ["explain"])
    }

    func testTheCardInsertsTheMeaning() {
        set("what does btw mean")
        model.perform(.explain)
        guard case .card(.meaning(let m))? = model.explainPanel else { return XCTFail("no card") }
        XCTAssertEqual(m.example.isEmpty, false)
        model.insertExplain()
        XCTAssertEqual(host.text, "what does btw mean by the way")
        XCTAssertNil(model.explainPanel)
    }

    func testATopicAsksTheServerOnceAfterThePause() async {
        set("explain log function")
        XCTAssertEqual(api.calls, [])
        await pass(KeyboardModel.explainDebounce)
        await until("explain answer") { model.explainOffer != nil }
        XCTAssertEqual(api.calls, ["explain"], "and no /v1/suggest")
        XCTAssertEqual(api.explained, ["explain log function"])
        XCTAssertEqual(model.barItems.first?.trigger, "log function")
        XCTAssertEqual(model.barItems.first?.title, "A log is the power you need.")
        // Typing on and back hits the cache.
        set("explain log function!")
        set("explain log function")
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(api.calls, ["explain"])
    }

    func testTypingOnBeforeThePauseSendsNothing() async {
        set("explain lo")
        await until("debounce sleep") { clock.sleeps.count == 1 }
        set("explain log function")
        await until("second sleep") { clock.sleeps.count == 2 }
        clock.advance(KeyboardModel.explainDebounce.seconds)
        await until("explain answer") { model.explainOffer != nil }
        XCTAssertEqual(api.explained, ["explain log function"])
    }

    func testAnAnswerForOldTextIsDropped() async {
        set("explain log function")
        await pass(KeyboardModel.explainDebounce)
        await until("explain call") { api.calls == ["explain"] }
        set("ok never mind")
        for _ in 0..<50 { await Task.yield() }
        XCTAssertNil(model.explainOffer)
    }

    func testASecretIsNeverSent() async {
        set("explain 4242 4242 4242 4242")
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(clock.sleeps, [])
        XCTAssertEqual(api.calls, [])
    }

    func testShowVisuallyGetsTheSceneAndCopyImageSavesIt() async {
        final class Page: VisualPage {
            var played: [Data] = []
            var exports = 0
            func play(_ scene: Data) { played.append(scene) }
            func replay() {}
            var tools: [VisualState.Tool] = []
            var undos = 0
            func setTool(_ tool: VisualState.Tool) { tools.append(tool) }
            func undo() { undos += 1 }
            func redo() {}
            func setVoice(_ on: Bool) {}
            func next() {}
            func exportPNG() { exports += 1 }
        }
        set("explain log function")
        await pass(KeyboardModel.explainDebounce)
        await until("explain answer") { model.explainOffer != nil }
        model.perform(.explain)
        model.showVisual()
        XCTAssertTrue(model.visualOpen)
        XCTAssertEqual(model.keyboardHeight, Theme.SystemKeyboard.visualHeight)
        let page = Page()
        model.visualPageReady(page)
        await until("scene") { page.played.count == 1 }
        XCTAssertEqual(api.calls, ["explain", "visual"])
        XCTAssertEqual(api.explained.last, "log function")
        model.visualStep(2, of: 4, say: "Draw y = log(x).")
        guard case .visual(let mid)? = model.explainPanel else { return XCTFail("panel closed") }
        XCTAssertEqual(mid.say, "Draw y = log(x).")
        model.selectVisualTool(.draw)
        model.selectVisualTool(.eraser)
        model.selectVisualTool(.eraser)
        model.undoVisual()
        XCTAssertEqual(page.tools, [.draw, .eraser, .hand])
        XCTAssertEqual(page.undos, 1)
        model.visualDone()
        model.toggleExport()
        model.sendVisual(.image)
        XCTAssertEqual(page.exports, 1)
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        model.visualExported(png)
        XCTAssertEqual(pasteboard.png, png)
        XCTAssertEqual(store.drawings.map(\.title), ["log function"])
        guard case .visual(let v)? = model.explainPanel else { return XCTFail("panel closed") }
        XCTAssertEqual(v.note, KeyboardModel.pasteHint)

        model.sendVisual(.link)
        XCTAssertEqual(page.exports, 2)
        model.visualExported(png)
        await until("link") { host.text.hasSuffix(".png") }
        XCTAssertEqual(api.shared, [png])
        XCTAssertEqual(host.text, "explain log function " + api.shareReply)
        guard case .visual(let v2)? = model.explainPanel else { return XCTFail("panel closed") }
        XCTAssertEqual(v2.note, "Link added. Tap send.")
        XCTAssertEqual(store.drawings.count, 2)
        host.text = "explain log function"
        model.insertExplain()
        XCTAssertEqual(host.text, "explain log function A log is the power you need.")
        XCTAssertEqual(model.keyboardHeight, Theme.SystemKeyboard.height)
    }
}
