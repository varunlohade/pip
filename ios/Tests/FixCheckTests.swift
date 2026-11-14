import XCTest
@testable import Pip

/// The on-device Fix check, with the real system spell checker.
final class FixCheckTests: XCTestCase {
    private func plan(_ text: String, names: [String] = [], skipLast: Bool = false) -> FixPlan? {
        FixCheck.plan(text, names: names, skipLast: skipLast)
    }

    func testTwoTyposNameTheCountAndFixOnThePhone() {
        let p = plan("yes it's availble, can u pick it up today")
        XCTAssertEqual(p?.title, "Fix 2 typos")
        XCTAssertEqual(p?.done, "Fixed 2 typos \u{2713}")
        XCTAssertEqual(p?.fixed, "Yes it's available, can you pick it up today?")
    }

    func testOneShortTypoShowsTheWord() {
        let p = plan("i can do teh job")
        XCTAssertEqual(p?.title, "Fix \u{201C}teh\u{201D} \u{2192} \u{201C}the\u{201D}")
        XCTAssertEqual(p?.done, "Fixed 1 typo \u{2713}")
        XCTAssertEqual(p?.fixed, "I can do the job.")
    }

    func testContractionSlips() {
        XCTAssertEqual(plan("I dont think so, im busy")?.fixed, "I don't think so, I'm busy.")
        XCTAssertEqual(plan("Dont worry about it")?.fixed, "Don't worry about it.")
    }

    func testCapitalsOnly() {
        let p = plan("see you then. i will bring it")
        XCTAssertEqual(p?.title, "Fix capitals")
        XCTAssertEqual(p?.done, "Fixed capitals \u{2713}")
        XCTAssertEqual(p?.fixed, "See you then. I will bring it.")
        XCTAssertEqual(plan("Sure, i'll be there")?.fixed, "Sure, I'll be there.")
    }

    func testDoubleSpace() {
        let p = plan("See you  at noon")
        XCTAssertEqual(p?.title, "Fix spacing")
        XCTAssertEqual(p?.fixed, "See you at noon.")
    }

    func testCleanTextShowsNoChip() {
        XCTAssertNil(plan("See you at noon"))
        XCTAssertNil(plan("Thanks, see you then!"))
        XCTAssertNil(plan("Can you do Tuesday?"))
        XCTAssertNil(plan("Ok sounds good lol"), "chat words are not typos")
    }

    func testLongCleanTextShowsNoChip() {
        XCTAssertNil(plan("The cut and color will take about two hours on Friday"), "grammar lives in the Rewrite panel, not the bar")
    }

    func testNamesLinksEmailsAmountsAreNotTypos() {
        XCTAssertNil(plan("Thanks Priyanka, see you Tuesday"), "a capital word mid-sentence is a name")
        XCTAssertNil(plan("Send $120 to https://ex.me/xq7zk now"))
        XCTAssertNil(plan("Mail it to jdoe@qmail.co please"))
        XCTAssertNil(plan("See pp.me/abcd or www.zqxw.com"))
        XCTAssertNil(plan("Order ORD-0042 is #42"))
        XCTAssertNil(plan("Priyanka booked a cut", names: ["Priyanka"]), "a name at the start, from the known names")
    }

    func testKnownNamesAreNotTypos() {
        XCTAssertEqual(plan("tell sanvika the cut is done", names: ["Sanvika Rao"])?.title, "Fix capitals",
                       "the known name is left alone; only the start gets a capital")
        XCTAssertEqual(plan("Tell sanvika the cut is done", names: ["Sanvika Rao"]), nil)
    }

    func testTheWordBeingTypedIsLeftAlone() {
        XCTAssertNil(plan("See you at noon teh", skipLast: true))
        XCTAssertNotNil(plan("See you at noon teh"))
    }

    func testAnotherLanguageIsNotFullOfTypos() {
        XCTAssertNil(plan("hola que tal estoy bien gracias"))
    }

    /// Half the words are wrong, but each has an everyday English word close by: typos, not another language.
    func testEnglishFullOfTyposStillGetsFixed() {
        let p = plan("I wil send teh report tomorow")
        XCTAssertEqual(p?.title, "Fix 3 typos")
        XCTAssertEqual(p?.fixed, "I will send the report tomorrow.")
    }

    func testHindiAndSpanishInLatinLettersGetNoChip() {
        XCTAssertNil(plan("kal milte hain bhai"))
        XCTAssertNil(plan("nos vemos mañana amigo"))
    }

    func testSpellerIsOnlyAskedAboutRealWords() {
        var asked: [String] = []
        _ = FixCheck.plan("Send Sam $45 at sam@x.com or pp.me/abc, ok?", spell: { asked.append($0); return .ok })
        XCTAssertEqual(asked, ["Send"], "names mid-sentence, amounts, emails, links and chat words are skipped")
    }
}

@MainActor
final class FixModelTests: XCTestCase {
    private var host: FakeHost!
    private var api: FakeAPI!
    private var clock: FakeClock!
    private var model: KeyboardModel!

    override func setUp() async throws {
        host = FakeHost()
        api = FakeAPI()
        clock = FakeClock()
        model = KeyboardModel(deps: .fake(api: api, clock: clock))
        model.host = host
        model.keyboardAppeared()
    }

    override func tearDown() async throws {
        model.keyboardDisappeared()
        model = nil
    }

    /// Types, waits for the off-thread check (30 ms of real time), then lets the fingers settle on the fake clock.
    private func typeAndSettle(_ text: String) async {
        let waits = { self.clock.sleeps.filter { $0 == ChipTiming.settle || $0 == ChipTiming.settleMidWord }.count }
        let before = waits()
        host.text = text
        model.textChanged()
        for _ in 0..<150 where waits() == before { try? await Task.sleep(for: .milliseconds(2)) }
        clock.advance(ChipTiming.settleMidWord.seconds)
        for _ in 0..<50 { await Task.yield() }
    }

    func testLocalFixNeedsNoServerAndUndoPutsItBack() async {
        await typeAndSettle("can u send teh bill ")
        XCTAssertEqual(model.fixPlan?.title, "Fix 2 typos")
        model.fix()
        XCTAssertEqual(host.text, "Can you send the bill?")
        // TestFlight 0.4: no line says the typo was fixed. Backspace right after puts the typed text back.
        XCTAssertFalse(model.barItems.contains { $0.title.hasPrefix("Fixed") }, "\(model.barItems.map(\.title))")
        XCTAssertNil(model.undo)
        XCTAssertFalse(api.calls.contains("fix"))
        let f = ObjectIdentifier(NSObject())
        model.touchBegan(f, KeyCap(id: "delete", kind: .delete, frame: .zero, a11y: "delete"))
        model.touchEnded(f)
        XCTAssertEqual(host.text, "can u send teh bill ")
        await typeAndSettle(host.text)
        XCTAssertNil(model.fixPlan, "Fix is not offered again for text the owner kept")
    }

    /// The word still being typed is left out of the chip, so the tap leaves it alone too.
    func testTapAppliesExactlyWhatTheChipSaid() async {
        await typeAndSettle("can u send teh bill tomorow")
        let chip = try? XCTUnwrap(model.fixPlan)
        XCTAssertEqual(chip?.title, "Fix 2 typos")
        model.fix()
        XCTAssertEqual(host.text, chip?.fixed)
        XCTAssertTrue(host.text.contains("tomorow"), "the word being typed is left alone: \(host.text)")
        XCTAssertFalse(model.barItems.contains { $0.title.hasPrefix("Fixed") })
    }

    func testCleanShortTextHasNoChip() {
        host.text = "See you at noon"
        model.textChanged()
        XCTAssertNil(model.fixPlan)
    }

    func testFixedGrammarIsOneRowOfTheRewriteListAndPreviewsFirst() async {
        let text = "The cut and color will take about two hours on Friday"
        await typeAndSettle(text)
        XCTAssertNil(model.fixPlan, "no grammar chip in the bar")
        model.toggleWrite()
        XCTAssertEqual(api.rewrites.last?.tones.last, "fix")
        api.send(.fix, "The cut and colour will take about two hours on Friday.")
        for _ in 0..<500 { if case .versions(let l) = model.writePanel, l.rows.last?.text != nil { break }; await Task.yield() }
        guard case .versions(let l) = model.writePanel else { return XCTFail("no list: \(model.writePanel)") }
        XCTAssertEqual(l.rows.last?.tone.title, "Fixed grammar")
        XCTAssertEqual(host.text, text, "a version does not change the message until it is tapped")
        model.useRewrite(.fix)
        XCTAssertEqual(host.text, "The cut and colour will take about two hours on Friday.")
        XCTAssertEqual(model.undo?.label, "Replaced \u{2713}")
        XCTAssertEqual(model.lastWrite, "fix")
    }
}
