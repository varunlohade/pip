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
    private var model: KeyboardModel!

    override func setUp() async throws {
        host = FakeHost()
        api = FakeAPI()
        model = KeyboardModel(deps: .fake(api: api))
        model.host = host
        model.keyboardAppeared()
    }

    override func tearDown() async throws {
        model.keyboardDisappeared()
        model = nil
    }

    /// The Fix check runs off the main thread, 30 ms after the keys pause.
    private func settle() async {
        for _ in 0..<500 where model.fixPlan == nil { try? await Task.sleep(for: .milliseconds(2)) }
    }

    func testLocalFixNeedsNoServerAndUndoPutsItBack() async {
        host.text = "can u send teh bill "
        model.textChanged()
        await settle()
        XCTAssertEqual(model.fixPlan?.title, "Fix 2 typos")
        model.fix()
        XCTAssertEqual(host.text, "Can you send the bill?")
        XCTAssertEqual(model.barItems.first?.title, "Fixed 2 typos \u{2713}")
        XCTAssertFalse(api.calls.contains("fix"))
        model.perform(.undo)
        XCTAssertEqual(host.text, "can u send teh bill ")
        model.textChanged()
        XCTAssertNil(model.fixPlan, "Fix is not offered again for text the owner kept")
    }

    /// The word still being typed is left out of the chip, so the tap leaves it alone too.
    func testTapAppliesExactlyWhatTheChipSaid() async {
        host.text = "can u send teh bill tomorow"
        model.textChanged()
        await settle()
        let chip = try? XCTUnwrap(model.fixPlan)
        XCTAssertEqual(chip?.title, "Fix 2 typos")
        model.fix()
        XCTAssertEqual(host.text, chip?.fixed)
        XCTAssertTrue(host.text.contains("tomorow"), "the word being typed is left alone: \(host.text)")
        XCTAssertEqual(model.barItems.first?.title, "Fixed 2 typos \u{2713}")
    }

    func testCleanShortTextHasNoChip() {
        host.text = "See you at noon"
        model.textChanged()
        XCTAssertNil(model.fixPlan)
    }

    func testFixGrammarInRewriteGoesToTheServerAndPreviewsFirst() async {
        let text = "The cut and color will take about two hours on Friday"
        host.text = text
        model.textChanged()
        XCTAssertNil(model.fixPlan, "no grammar chip in the bar")
        api.writeReply = WriteResponse(text: "The cut and colour will take about two hours on Friday.", changed: true)
        model.toggleWrite()
        model.fixGrammar()
        for _ in 0..<500 where api.calls.filter({ $0 == "fix" }).isEmpty || model.writePanel == .busy("Checking the grammar\u{2026}") { await Task.yield() }
        XCTAssertEqual(api.calls.filter { $0 == "fix" }.count, 1)
        guard case .preview(let p) = model.writePanel else { return XCTFail("no preview: \(model.writePanel)") }
        XCTAssertEqual(p.title, "Fix grammar")
        XCTAssertEqual(host.text, text, "a preview does not change the message")
        model.usePreview()
        XCTAssertEqual(host.text, "The cut and colour will take about two hours on Friday.")
        XCTAssertEqual(model.undo?.label, "Replaced \u{2713}")
    }
}
