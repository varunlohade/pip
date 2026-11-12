import XCTest
@testable import Pip

/// Word slots, autocorrect on space, backspace undo and next-word guesses, through the model.
@MainActor
final class TypingWordsTests: XCTestCase {
    private var host: FakeHost!
    private var model: KeyboardModel!
    private let keys = KeyboardGeometry.keys(layout: .letters, width: 390, globe: false, currency: "$")

    override func setUp() async throws {
        host = FakeHost()
        host.autocapitalization = .none
        model = KeyboardModel(deps: .fake(api: FakeAPI()))
        model.host = host
        model.keyboardAppeared()
        await waitFor("language model") { KeyboardModel.language != nil }
    }

    override func tearDown() async throws {
        model.keyboardDisappeared()
        model = nil
    }

    /// Waits in real time: the slots refresh 30 ms after the last key, off the main thread.
    private func waitFor(_ what: String, timeout: TimeInterval = 10, _ cond: () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !cond(), Date() < end { try? await Task.sleep(for: .milliseconds(2)) }
        XCTAssertTrue(cond(), "timed out waiting for \(what)")
    }

    private func key(_ id: String) -> KeyCap { keys.first { $0.id == id }! }

    private func type(_ s: String) {
        for ch in s {
            if ch == " " { model.activate(key("space")); continue }
            model.activate(keys.first { $0.kind == .char(String(ch)) }!)
        }
    }

    private var slotWords: [String] { model.words.slots.map(\.word) }

    func testTheSlotsShowTheTypedWordAndTheFixBeforeSpace() async {
        type("say helo")
        await waitFor("slots for helo") { slotWords.first == "helo" }
        XCTAssertEqual(model.words.slots.first?.title, "\u{201C}helo\u{201D}")
        XCTAssertEqual(slotWords.count, 3)
        XCTAssertEqual(slotWords[1], "hello", "the middle slot is what space puts in")
        XCTAssertTrue(model.words.midWord)
    }

    func testSpaceFixesBackspacePutsItBackAndTheWordIsLeftAlone() {
        type("say helo ")
        XCTAssertEqual(host.text, "say hello ")
        model.activate(key("delete"))
        XCTAssertEqual(host.text, "say helo")
        model.activate(key("space"))
        XCTAssertEqual(host.text, "say helo ")
        type("helo ")
        XCTAssertEqual(host.text, "say helo helo ", "a word put back is not fixed again in this field")
    }

    func testShorthandIsNeverCorrected() {
        type("sry tmrw rn lmk omw ngl idk brb btw ")
        XCTAssertEqual(host.text, "sry tmrw rn lmk omw ngl idk brb btw ")
    }

    func testAfterASpaceTheSlotsGuessTheNextWord() async {
        type("see you ")
        await waitFor("next-word guesses") { !model.words.slots.isEmpty && !model.words.midWord }
        XCTAssertEqual(slotWords, ["soon", "tomorrow", "later"])
        model.useWord("soon")
        XCTAssertEqual(host.text, "see you soon ")
    }

    func testWordsThisPersonTypesComeFirstNextTime() async {
        type("lunch with you and lunch ")
        await waitFor("learned next word") { slotWords.first == "with" }
    }

    func testTappingASlotReplacesTheWordAndAddsASpace() async {
        type("tomor")
        await waitFor("slots for tomor") { slotWords.first == "tomor" }
        model.useWord("tomorrow")
        XCTAssertEqual(host.text, "tomorrow ")
    }

    func testAFieldWithAutocorrectOffKeepsTheTypo() {
        host.autocorrection = .no
        type("teh ")
        XCTAssertEqual(host.text, "teh ")
    }

    /// R1.1: the slots follow each key within 50 ms at p95 (30 ms of that is the wait for the keys to pause).
    func testSlotsRefreshWithinFiftyMillisecondsAtP95() async {
        var ms: [Double] = []
        let text = "can you send me the invoice for the meeting tomorrow morning please "
        for ch in text {
            if ch == " " { model.activate(key("space")) } else { model.activate(keys.first { $0.kind == .char(String(ch)) }!) }
            let before = host.text
            let start = ContinuousClock.now
            let want = Predictions.typedWord(before)
            await waitFor("slots for \(before)") { want == nil ? !model.words.midWord && !model.words.slots.isEmpty : slotWords.first == want }
            ms.append(Double((ContinuousClock.now - start) / .microseconds(1)) / 1000)
        }
        let p95 = ms.sorted()[Int(Double(ms.count - 1) * 0.95)]
        print(String(format: "PIP_TIMING word_slots_p95_ms=%.1f keys=%d", p95, ms.count))
        XCTAssertLessThan(p95, 50)
    }
}
