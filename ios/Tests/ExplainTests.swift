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

    func testRealTopicPhrasingsAcrossSubjects() {
        for (text, subject) in [
            ("explain the water cycle", "water cycle"),
            ("Explain the water cycle.", "water cycle"),
            ("EXPLAIN THE WATER CYCLE!", "water cycle"),
            ("explain the theory of relativity", "theory of relativity"),
            ("explain supply and demand", "supply and demand"),
            ("can you explain the french revolution?", "french revolution"),
            ("could you please explain the causes of world war 1", "causes of world war 1"),
            ("explain to me the krebs cycle", "krebs cycle"),
            ("explain the water cycle to me", "water cycle"),
            ("hey pip, explain the pythagorean theorem", "pythagorean theorem"),
            ("explain: the stock market", "stock market"),
            ("explain a black hole", "black hole"),
            ("Explain an electric circuit?", "electric circuit"),
            ("explain the rule of law", "rule of law"),
            ("explain cell division in plants", "cell division in plants"),
            ("explain the separation of powers", "separation of powers"),
            ("explain natural selection", "natural selection"),
            ("explain the big bang", "big bang"),
            ("explain the laws of motion...", "laws of motion"),
            ("explain the electoral college", "electoral college"),
            ("how does the internet work", "internet"),
            ("How does the stock market work?", "stock market"),
            ("how do vaccines work", "vaccines"),
            ("how does wifi work?!", "wifi"),
            ("how do solar panels work", "solar panels"),
            ("How does the human heart work", "human heart"),
            ("how does an electric motor work", "electric motor"),
            ("explain why the sky is blue", "why the sky is blue"),
            ("Explain why is the sky blue?", "why is the sky blue"),
            ("eli5 why do cats purr", "why do cats purr"),
            ("eli5 the water cycle", "water cycle"),
            ("ELI5 how vaccines work", "vaccines"),
            ("eli5: supply and demand", "supply and demand"),
            ("eli5 the theory of evolution?", "theory of evolution"),
            ("explain like i'm five the electoral college", "electoral college"),
            ("what is a black hole", "black hole"),
            ("What is a neural network?", "neural network"),
            ("what is an exoplanet", "exoplanet"),
            ("whats a tectonic plate", "tectonic plate"),
            ("what is a prime number.", "prime number"),
            ("What is a Supernova?", "supernova"),
        ] {
            let a = Explain.detect(text)
            XCTAssertEqual(a?.kind, .topic, text)
            XCTAssertEqual(a?.subject, subject, text)
        }
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
            "can you explain to mom", "explain the", "explain it to me later", "explain what you mean", "explain the thing you said",
            "why is he so mad", "why are you like this", "why do i bother", "why is it always me", "how does it work",
            "eli5 this", "explain to him", "what's the deal", "what is the score",
        ] {
            XCTAssertNil(Explain.detect(text), text)
        }
    }

    /// Explain is for "what is", "explain" and "meaning of" asks. An everyday why-question is chat.
    func testEverydayWhyQuestionsAreNotExplainAsks() {
        for text in [
            "why is the bus late", "Why is the bus so late?", "why is the sky blue", "why do cats purr", "why are leaves green?",
            "why does ice float", "why is my phone so slow", "why are the trains delayed again", "why does it always rain on sunday",
            "why do we have a meeting at 5", "so why is the bus late", "hey why are you late",
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
        store.signedIn = false
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
        let asks = { self.clock.sleeps.filter { $0 == KeyboardModel.explainDebounce }.count }
        set("explain lo")
        await until("debounce sleep") { asks() == 1 }
        set("explain log function")
        await until("second sleep") { asks() == 2 }
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
        XCTAssertFalse(clock.sleeps.contains(KeyboardModel.explainDebounce), "no ask is even scheduled: \(clock.sleeps)")
        XCTAssertEqual(api.calls, [])
    }

    /// The TestFlight 0.2 (3) report: "explain compound interest" did not draw. Every server answer offers Draw it,
    /// even when the model says a drawing would not help; a dictionary meaning and an unpaired keyboard do not.
    func testEveryServerAnswerOffersDrawIt() {
        let noHint = ExplainOffer.answer(subject: "compound interest", ExplainResponse(short: "Interest on interest.", body: "", visual_ok: false))
        XCTAssertTrue(model.paired)
        XCTAssertTrue(model.explainCanDraw(noHint))
        guard let btw = ExplainDictionary.shared.lookup("btw") else { return XCTFail("no btw") }
        XCTAssertFalse(model.explainCanDraw(.meaning(btw)))
        model.paired = false
        XCTAssertFalse(model.explainCanDraw(noHint))
    }

    func testShowVisuallyGetsTheSceneAndSendTypesTheLinkInOneTap() async {
        set("explain log function")
        await pass(KeyboardModel.explainDebounce)
        await until("explain answer") { model.explainOffer != nil }
        model.perform(.explain)
        model.showVisual()
        XCTAssertTrue(model.visualOpen)
        XCTAssertEqual(model.keyboardHeight, Theme.SystemKeyboard.visualHeight)
        let page = FakePage()
        model.visualPageReady(page)
        await until("scene") { page.played.count == 1 }
        XCTAssertEqual(api.calls, ["explain", "visual"])
        XCTAssertEqual(api.explained.last, "log function")
        model.visualStep(2, of: 4, say: "Draw y = log(x).")
        guard case .visual(let mid)? = model.explainPanel else { return XCTFail("panel closed") }
        XCTAssertEqual(mid.say, "Draw y = log(x).")
        XCTAssertEqual(page.exports, 0, "nothing goes up while it draws")
        model.selectVisualTool(.draw)
        model.selectVisualTool(.eraser)
        model.selectVisualTool(.eraser)
        model.undoVisual()
        XCTAssertEqual(page.tools, [.draw, .eraser, .hand])
        XCTAssertEqual(page.undos, 1)

        // The drawing finishes: its PNG and JPEG preview are made on the phone. Nothing goes up yet.
        model.visualDone()
        XCTAssertEqual(page.exports, 1)
        let png = Self.png
        model.visualExported(png)
        XCTAssertEqual(model.sharePrepared?.png, png)
        XCTAssertEqual(model.sharePrepared?.preview?.prefix(3), Data([0xFF, 0xD8, 0xFF]), "a JPEG preview")
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(api.shared.count, 0, "nothing leaves the phone before Send")
        XCTAssertEqual(store.drawings.count, 0)
        XCTAssertNil(pasteboard.png)
        guard case .visual(let ready)? = model.explainPanel else { return XCTFail("panel closed") }
        XCTAssertNil(ready.note, "making the preview is quiet")

        // One tap: it uploads, then the caption and link replace the typed request. The image is copied at once.
        model.sendVisual(.link)
        XCTAssertEqual(page.exports, 2)
        model.visualExported(png)
        XCTAssertEqual(note, KeyboardModel.sendingNote)
        XCTAssertEqual(pasteboard.png, png)
        await until("link") { host.text.hasSuffix(api.shareReply) }
        XCTAssertEqual(host.text, "log function, explained: " + api.shareReply)
        XCTAssertEqual(api.shared.count, 1)
        XCTAssertEqual(api.shared[0].png, png)
        XCTAssertEqual(api.shared[0].preview, model.sharePrepared?.preview, "the preview made ahead is the one sent")
        XCTAssertEqual(api.shared[0].title, "log function")
        XCTAssertEqual(store.drawings.map(\.title), ["log function"])
        guard case .visual(let sent)? = model.explainPanel else { return XCTFail("panel closed") }
        XCTAssertEqual(sent.note, KeyboardModel.linkAdded)
        XCTAssertEqual(sent.hint, KeyboardModel.imageAlsoCopied)
        XCTAssertNil(sent.sending)

        // Send as image stays in the small menu.
        model.toggleExport()
        guard case .visual(let menu)? = model.explainPanel else { return XCTFail("panel closed") }
        XCTAssertTrue(menu.exporting)
        XCTAssertNil(menu.hint)
        model.sendVisual(.image)
        XCTAssertEqual(page.exports, 3)
        model.visualExported(png)
        guard case .visual(let copied)? = model.explainPanel else { return XCTFail("panel closed") }
        XCTAssertEqual(copied.note, KeyboardModel.pasteHint)
        XCTAssertNil(copied.hint)
        XCTAssertEqual(store.drawings.count, 2)
        XCTAssertEqual(api.shared.count, 1)

        host.text = "explain log function"
        model.insertExplain()
        XCTAssertEqual(host.text, "explain log function A log is the power you need.")
        XCTAssertEqual(model.keyboardHeight, Theme.SystemKeyboard.height)
    }

    /// A graph opens its drawing at once; the page reports it finished, and its PNG comes back.
    @discardableResult
    private func drawnGraph(_ text: String = "graph y = x^2") -> FakePage {
        set(text)
        model.tapExplainChip()
        let page = FakePage()
        model.visualPageReady(page)
        model.visualDone()
        model.visualExported(Self.png)
        return page
    }

    private func send(_ png: Data = ExplainModelTests.png) {
        model.sendVisual(.link)
        model.visualExported(png)
    }

    private var note: String? { if case .visual(let v)? = model.explainPanel { return v.note }; return nil }
    private var hint: String? { if case .visual(let v)? = model.explainPanel { return v.hint }; return nil }

    func testSendSaysSendingUntilTheUploadEndsThenTypesTheLink() async {
        api.holdShares = true
        let page = drawnGraph()
        send()
        XCTAssertEqual(page.exports, 2)
        await until("upload") { api.shared.count == 1 }
        XCTAssertEqual(note, KeyboardModel.sendingNote)
        XCTAssertEqual(host.text, "graph y = x^2")
        XCTAssertEqual(pasteboard.png, Self.png, "the image is copied at the same moment")
        api.releaseShares()
        await until("link") { host.text.hasSuffix(api.shareReply) }
        XCTAssertEqual(host.text, "y = x^2, explained: " + api.shareReply)
        XCTAssertEqual(note, KeyboardModel.linkAdded)
        XCTAssertEqual(hint, KeyboardModel.imageAlsoCopied)
    }

    func testTextBeforeTheRequestStays() async {
        drawnGraph("ha ok. graph y = x^2")
        send()
        await until("link") { host.text.hasSuffix(api.shareReply) }
        XCTAssertEqual(host.text, "ha ok. y = x^2, explained: " + api.shareReply)
    }

    func testWhenTheRequestIsNoLongerLastTheLinkGoesAfterTheText() async {
        drawnGraph()
        host.text = "graph y = x^2. see this"
        send()
        await until("link") { host.text.hasSuffix(api.shareReply) }
        XCTAssertEqual(host.text, "graph y = x^2. see this y = x^2, explained: " + api.shareReply)
    }

    func testAnUploadSlowerThanFiveSecondsFallsBackToTheCopiedImage() async {
        api.holdShares = true
        drawnGraph()
        send()
        await until("the wait") { clock.sleeps.contains(KeyboardModel.shareWait) }
        clock.advance(KeyboardModel.shareWait.seconds)
        await until("fallback") { note == KeyboardModel.pasteHint }
        XCTAssertNil(hint)
        XCTAssertEqual(host.text, "graph y = x^2", "no link")
        XCTAssertEqual(pasteboard.png, Self.png)
        guard case .visual(let v)? = model.explainPanel else { return XCTFail("panel closed") }
        XCTAssertNil(v.sending, "Send works again")
        api.releaseShares()
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(host.text, "graph y = x^2", "a late link is dropped")
        XCTAssertEqual(note, KeyboardModel.pasteHint)
    }

    func testAFailedUploadFallsBackAndTheNextSendTriesAgain() async {
        api.shareFails = true
        drawnGraph()
        send()
        await until("fallback") { note == KeyboardModel.pasteHint }
        XCTAssertEqual(host.text, "graph y = x^2")
        XCTAssertEqual(pasteboard.png, Self.png)
        api.shareFails = false
        send()
        await until("link") { host.text.hasSuffix(api.shareReply) }
        XCTAssertEqual(api.shared.count, 2)
    }

    func testADrawingChangedWithThePenGetsANewPreview() async {
        drawnGraph()
        let first = model.sharePrepared?.preview
        let edited = Self.makePNG(width: 410, height: 250)
        send(edited)
        await until("link") { host.text.hasSuffix(api.shareReply) }
        XCTAssertEqual(api.shared.map(\.png), [edited])
        XCTAssertNotNil(api.shared[0].preview)
        XCTAssertNotEqual(api.shared[0].preview, first)
    }

    func testWithoutFullAccessNothingIsMadeOrSent() {
        host.hasFullAccess = false
        model.keyboardAppeared()
        set("graph y = x^2")
        model.tapExplainChip()
        let page = FakePage()
        model.visualPageReady(page)
        model.visualDone()
        XCTAssertEqual(page.exports, 0)
        model.sendVisual(.link)
        XCTAssertEqual(page.exports, 0)
        XCTAssertEqual(note, KeyboardModel.needsFullAccessToSend)
    }

    func testThePreviewIsASmallJPEGAtLeast600Wide() throws {
        let small = try XCTUnwrap(LinkPreview.jpeg(Self.png))
        XCTAssertEqual(small.prefix(3), Data([0xFF, 0xD8, 0xFF]))
        XCTAssertEqual(UIImage(data: small)?.cgImage?.width, 600)
        XCTAssertEqual(UIImage(data: small)?.cgImage?.height, 375)
        // A big, busy drawing still fits the 300 KB WhatsApp keeps.
        let big = try XCTUnwrap(LinkPreview.jpeg(Self.makePNG(width: 2400, height: 1600, noise: true)))
        XCTAssertLessThanOrEqual(big.count, LinkPreview.maxBytes)
        let w = try XCTUnwrap(UIImage(data: big)?.cgImage?.width)
        XCTAssertTrue((600...1200).contains(w), "\(w)")
        XCTAssertNil(LinkPreview.jpeg(Data([0x89, 0x50, 0x4E, 0x47])))
    }

    static let png = makePNG(width: 400, height: 250)

    static func makePNG(width: Int, height: Int, noise: Bool = false) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).pngData { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            UIColor.systemBlue.setStroke()
            ctx.stroke(CGRect(x: 20, y: 20, width: width - 40, height: height - 40))
            guard noise else { return }
            var seed: UInt64 = 42
            for x in stride(from: 0, to: width, by: 4) {
                for y in stride(from: 0, to: height, by: 4) {
                    seed = seed &* 6364136223846793005 &+ 1442695040888963407
                    UIColor(hue: CGFloat(seed >> 40 & 255) / 255, saturation: 0.8, brightness: 0.9, alpha: 1).setFill()
                    ctx.fill(CGRect(x: x, y: y, width: 4, height: 4))
                }
            }
        }
    }
}

/// The drawing page, recording what the keyboard asked of it.
@MainActor
final class FakePage: VisualPage {
    var played: [Data] = []
    var exports = 0
    var tools: [VisualState.Tool] = []
    var undos = 0
    func play(_ scene: Data) { played.append(scene) }
    func replay() {}
    func setTool(_ tool: VisualState.Tool) { tools.append(tool) }
    func undo() { undos += 1 }
    func redo() {}
    func setVoice(_ on: Bool) {}
    func next() {}
    func exportPNG() { exports += 1 }
}
