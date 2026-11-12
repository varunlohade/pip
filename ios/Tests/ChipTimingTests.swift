import Combine
import XCTest
@testable import Pip

/// Chip timing on a fake clock: chips leave at once, new ones wait for the fingers to settle, ✕ and typing past
/// start a cooldown, the copied text expires, the server is asked after a real pause, and rewrites stream in.
@MainActor
final class ChipTimingTests: XCTestCase {
    private var host: FakeHost!
    private var api: FakeAPI!
    private var clock: FakeClock!
    private var store: FakeStore!
    private var writer: FakeWriter!
    private var pasteboard: FakePasteboard!
    private var model: KeyboardModel!

    override func setUp() async throws {
        host = FakeHost()
        api = FakeAPI()
        clock = FakeClock()
        store = FakeStore()
        writer = FakeWriter()
        pasteboard = FakePasteboard()
        model = KeyboardModel(deps: .fake(api: api, store: store, pasteboard: pasteboard, clock: clock, writer: writer))
        model.host = host
        model.keyboardAppeared()
    }

    override func tearDown() async throws {
        model.keyboardDisappeared()
        model = nil
    }

    /// Waits on the condition itself, up to a few real seconds, so a slow machine does not fail it.
    private func until(_ what: String, _ cond: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !cond(), ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(cond(), "timed out waiting for \(what)")
    }

    private func settle() async { for _ in 0..<50 { await Task.yield() } }

    private func set(_ text: String) {
        host.text = text
        model.textChanged()
    }

    /// Moves the clock and lets the woken tasks run.
    private func advance(_ s: TimeInterval) async {
        await settle()
        clock.advance(s)
        await settle()
    }

    /// Types `text` one key at a time, `gap` seconds apart.
    private func type(_ text: String, gap: TimeInterval = 0.15) async {
        for ch in text {
            host.text.append(ch)
            model.textChanged()
            await advance(gap)
        }
    }

    private func item(_ id: String) -> BarItems.Item? { model.barItems.first { $0.id == id } }

    // MARK: G4: a chip leaves at once, and a tap re-reads the text

    func testChipLeavesOnTheSameKey() async {
        set("dinner friday 7pm")
        await advance(0.4)
        await until("event chip") { !model.smart.isEmpty }
        set("dinner friday 7pm. ok thanks")
        XCTAssertEqual(model.smart, [], "no pause: the chip goes on the key that made it stale")
    }

    func testAChipThatStillAppliesStaysWhileTypingOn() async {
        set("dinner with Ana friday 7pm")
        await advance(0.4)
        await until("event chip") { item("smart.event") != nil }
        set("dinner with Ana friday 7pm at")
        XCTAssertNotNil(item("smart.event"), "still true, so it stays put with no blink")
    }

    func testANewChipWaitsForTheSettle() async {
        set("call supplier at 5")
        await advance(0.39)
        XCTAssertEqual(model.smart, [])
        await advance(0.02)
        await until("reminder chip") { !model.smart.isEmpty }
    }

    func testStaleTapDoesNothing() async {
        set("dinner friday 7pm")
        await advance(0.4)
        await until("event chip") { !model.smart.isEmpty }
        let chip = model.smart[0]
        host.text = "dinner friday 7pm. never mind"  // the tap lands before the bar caught up
        model.tapSmart(chip)
        XCTAssertTrue(writer.events.isEmpty, "a stale chip adds nothing")
        XCTAssertEqual(model.smart, [], "and it goes")
    }

    func testStaleCalcTapTypesNothing() {
        set("12*7")
        XCTAssertNotNil(item("explain"), "a sum shows at once, with no wait")
        host.text = "12*7 is what i said"
        model.tapExplainChip()
        XCTAssertEqual(host.text, "12*7 is what i said")
    }

    // MARK: G5: Fix waits for the settle and never blinks

    /// Fix waits on the fake clock only after its check ran off the main thread (30 ms of real time).
    private func fixWaits() -> Int { clock.sleeps.filter { $0 == ChipTiming.settle || $0 == ChipTiming.settleMidWord }.count }
    private func waitForFixCheck(_ before: Int) async {
        for _ in 0..<500 where fixWaits() == before { try? await Task.sleep(for: .milliseconds(2)) }
        XCTAssertGreaterThan(fixWaits(), before, "the Fix check never ran")
    }
    private func waitReal(_ what: String, _ cond: () -> Bool) async {
        for _ in 0..<500 where !cond() { try? await Task.sleep(for: .milliseconds(2)) }
        XCTAssertTrue(cond(), "timed out waiting for \(what)")
    }

    func testFixWaitsForTheFingersToSettleAndDoesNotBlink() async {
        var toggles = 0
        var shown = false
        let sub = model.$fixPlan.sink { p in if (p != nil) != shown { shown = p != nil; toggles += 1 } }
        defer { sub.cancel() }
        await type("can u send teh bill ")
        XCTAssertNil(model.fixPlan, "nothing mid-burst")
        let before = fixWaits()
        await waitForFixCheck(before)
        await advance(0.35)
        XCTAssertNil(model.fixPlan, "350 ms into the settle: not yet")
        await advance(0.1)
        await until("fix chip") { model.fixPlan != nil }
        await type("by friday please ok")
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertNotNil(model.fixPlan)
        XCTAssertEqual(toggles, 1, "Fix showed once and stayed")
    }

    func testFixMidWordWaitsOneSecond() async {
        let before = fixWaits()
        set("can u send teh bi")
        await waitForFixCheck(before)
        await advance(0.5)
        XCTAssertNil(model.fixPlan, "half a word: 0.4 s is not enough")
        await advance(0.55)
        await until("fix chip") { model.fixPlan != nil }
    }

    func testFixLeavesAsSoonAsTheTextIsClean() async {
        let before = fixWaits()
        set("can u send teh bill ")
        await waitForFixCheck(before)
        await advance(0.4)
        await until("fix chip") { model.fixPlan != nil }
        set("Can you send the bill? ")
        await waitReal("fix gone, with no settle wait") { model.fixPlan == nil }
    }

    // MARK: G6: ✕, cooldowns, copied text

    func testDismissQuietsEveryChipForTenSeconds() async {
        set("call supplier at 5")
        await advance(0.4)
        await until("reminder chip") { !model.smart.isEmpty }
        model.dismissChips()
        XCTAssertEqual(model.smart, [])
        XCTAssertNil(model.barItems.first { BarItems.dismissible($0) })
        await advance(9.5)
        set("call supplier at 6")
        await advance(0.4)
        XCTAssertEqual(model.smart, [], "9.9 s after ✕: still quiet")
        set("12*7")
        XCTAssertNil(model.explainOffer, "no chip of any kind, not even a sum")
        await advance(0.2)
        set("call supplier at 7")
        await advance(0.4)
        await until("chip back after 10 s") { !model.smart.isEmpty }
    }

    func testDismissedChipDoesNotComeBackForTheSameText() async {
        set("call supplier at 5")
        await advance(0.4)
        await until("reminder chip") { !model.smart.isEmpty }
        model.dismissChips()
        await advance(11)
        model.textChanged()
        await advance(0.5)
        XCTAssertEqual(model.smart, [], "same text, same answer: it stays away")
    }

    func testTypingTwoWordsPastAChipQuietsFiveSeconds() async {
        set("call supplier at 5")
        await advance(0.4)
        await until("reminder chip") { !model.smart.isEmpty }
        await advance(1)
        set("call supplier at 5 and then")
        XCTAssertEqual(model.smart, [], "typed past: the chip goes")
        await advance(0.5)
        XCTAssertEqual(model.smart, [], "and none comes back yet")
        await advance(4)
        set("call supplier at 5 and then tea")
        await advance(0.5)
        XCTAssertEqual(model.smart, [], "4.9 s: still quiet")
        await advance(0.2)
        set("call supplier at 5 and then tea!")
        await advance(0.4)
        await until("chip after 5 s") { !model.smart.isEmpty }
    }

    func testAGlimpseUnderOneSecondDoesNotCount() async {
        set("call supplier at 5")
        await advance(0.4)
        await until("reminder chip") { !model.smart.isEmpty }
        await advance(0.5)
        set("call supplier at 5 and then")
        XCTAssertFalse(model.smart.isEmpty, "seen for 0.5 s only: no cooldown")
    }

    func testNewFieldStartsWithNoCooldown() async {
        set("call supplier at 5")
        await advance(0.4)
        await until("reminder chip") { !model.smart.isEmpty }
        model.dismissChips()
        model.keyboardAppeared()
        set("call supplier at 9")
        await advance(0.4)
        await until("chip in the new field") { !model.smart.isEmpty }
    }

    func testCopiedTextIsOfferedForThreeMinutesOnce() async {
        pasteboard.copy("Is this still available?")
        model.keyboardAppeared()
        XCTAssertNotNil(item("copied"))
        await advance(179)
        XCTAssertTrue(model.copiedAvailable)
        await advance(2)
        await until("copied chip expired") { !model.copiedAvailable }
        XCTAssertNil(item("copied"))
        model.keyboardAppeared()
        XCTAssertNil(item("copied"), "once per copy")
        pasteboard.copy("New message")
        model.keyboardAppeared()
        XCTAssertNotNil(item("copied"), "a new copy is offered again")
    }

    func testDismissOrTypingEndsTheCopiedOffer() async {
        pasteboard.copy("first")
        model.keyboardAppeared()
        model.dismissChips()
        XCTAssertNil(item("copied"))
        model.keyboardAppeared()
        XCTAssertNil(item("copied"), "✕ ends it for good")
        pasteboard.copy("second")
        model.keyboardAppeared()
        XCTAssertNotNil(item("copied"))
        set("h")
        XCTAssertFalse(model.copiedAvailable, "typing ends it")
        set("")
        model.keyboardAppeared()
        XCTAssertNil(item("copied"))
    }

    // MARK: G9: the server is asked after a real pause, and again when the sentence grows

    func testServerIsAskedAfter700msThenAgainWhenTheSentenceGrows() async {
        set("can we sort out Ana's thing")
        await advance(0.6)
        XCTAssertEqual(api.suggested.count, 0, "600 ms: no call")
        await advance(0.11)
        await until("first ask") { api.suggested.count == 1 }
        set("can we sort out Ana's thing on")
        await advance(0.71)
        XCTAssertEqual(api.suggested.count, 1, "one more word: no new ask")
        set("can we sort out Ana's thing on friday")
        await advance(0.71)
        await until("second ask") { api.suggested.count == 2 }
        XCTAssertEqual(api.suggested.last?.text, "can we sort out Ana's thing on friday", "the whole sentence goes")
        model.textChanged()
        await advance(0.71)
        XCTAssertEqual(api.suggested.count, 2, "the same version never goes twice")
    }

    func testShortSentencesAreNotSent() async {
        for text in ["Ana's thing?", "call Ana 5"] {
            set(text)
            await advance(1)
        }
        XCTAssertEqual(api.suggested.count, 0)
    }

    func testEverydayWhyQuestionIsNotExplained() async {
        set("why is the bus late")
        XCTAssertNil(model.explainOffer)
        await advance(1)
        XCTAssertEqual(api.explained, [])
    }

    // MARK: G7: rewrites stream into one list

    private func rows() -> [RewriteRow] {
        if case .versions(let l) = model.writePanel { return l.rows }
        return []
    }
    private func status(_ t: RefineTone) -> RewriteRow.Status? { rows().first { $0.tone == t }?.status }

    func testRewriteStreamsEveryVersionSkipsTheStalledOneAndRetries() async {
        set("pay me by friday")
        model.toggleWrite()
        XCTAssertEqual(api.rewrites.map(\.tones), [RefineTone.allCases.map(\.rawValue)], "one call for every version")
        XCTAssertEqual(rows().map(\.status), Array(repeating: .writing, count: RefineTone.allCases.count))

        await advance(0.5)
        api.send(.polite, "Could you pay by Friday, please?")
        await until("first version") { status(.polite) == .ready("Could you pay by Friday, please?") }
        XCTAssertEqual(status(.shorter), .writing, "the rest are still coming")

        await advance(2.5)  // a slow model: it lands at 3 s, still in time
        for t in [RefineTone.shorter, .professional, .friendly, .firmer] { api.send(t, "\(t.title): pay by Friday.") }
        await until("slow versions") { status(.firmer) == .ready("Firmer: pay by Friday.") }

        await advance(1)  // 4 s: the grammar fix never started
        await until("stalled row") { status(.fix) == .stalled }
        model.retryRewrite(.fix)
        XCTAssertEqual(api.rewrites.last?.tones, ["fix"], "Retry asks only for that version")
        XCTAssertEqual(status(.fix), .writing)
        XCTAssertEqual(status(.polite), .ready("Could you pay by Friday, please?"), "the others stay")
        api.send(.fix, "Pay me by Friday.")
        await until("retried version") { status(.fix) == .ready("Pay me by Friday.") }

        model.copyRewrite(.polite)
        XCTAssertEqual(pasteboard.string, "Could you pay by Friday, please?", "hold copies")
        XCTAssertEqual(store.lastPasteboardChange, pasteboard.changeCount, "our own copy is not offered back")
        XCTAssertTrue(model.writeOpen, "the list stays open after a copy")

        model.useRewrite(.shorter)
        XCTAssertEqual(host.text, "Shorter: pay by Friday.", "tap replaces")
        XCTAssertFalse(model.writeOpen)
        XCTAssertEqual(model.undo?.label, "Replaced \u{2713}")
    }

    func testAVersionCanBeUsedWhileOthersAreStillWriting() async {
        set("pay me by friday")
        model.toggleWrite()
        api.send(.friendly, "Hey! Could you pay by Friday?")
        await until("one version") { status(.friendly) != .writing }
        model.useRewrite(.friendly)
        XCTAssertEqual(host.text, "Hey! Could you pay by Friday?")
    }

    func testFinishedRewriteBatchesAreDropped() async {
        set("pay me by friday")
        model.toggleWrite()
        XCTAssertEqual(model.rewriteBatches.count, 1)
        for t in RefineTone.allCases { api.send(t, "\(t.title): pay by Friday.") }
        api.endRewrite()
        await until("first call done") { model.rewriteBatches.isEmpty }
        for _ in 0..<3 {
            model.retryRewrite(.fix)
            XCTAssertEqual(model.rewriteBatches.count, 1)
            api.send(.fix, "Pay me by Friday.")
            api.endRewrite()
            await until("retry done") { model.rewriteBatches.isEmpty }
        }
        model.retryRewrite(.fix)
        await advance(8.1)
        await until("timed-out call dropped") { model.rewriteBatches.isEmpty }
    }

    func testRewriteThatNeverAnswersFailsAt8sWithRetry() async {
        set("pay me by friday")
        model.toggleWrite()
        await advance(4)
        await until("all stalled") { rows().allSatisfy { $0.status == .stalled } }
        await advance(3.9)
        XCTAssertNotEqual(model.writePanel, .failed(KeyboardModel.rewriteFailed), "7.9 s: not yet")
        await advance(0.2)
        await until("failed line") { model.writePanel == .failed(KeyboardModel.rewriteFailed) }
        model.retryRewrite()
        XCTAssertEqual(api.rewrites.count, 2)
        XCTAssertEqual(api.rewrites.last?.tones.count, RefineTone.allCases.count)
        XCTAssertEqual(rows().map(\.status), Array(repeating: .writing, count: RefineTone.allCases.count))
    }

    func testStaleRewriteTapDoesNotReplace() async {
        set("pay me by friday")
        model.toggleWrite()
        api.send(.polite, "Could you pay by Friday, please?")
        await until("version") { status(.polite) != .writing }
        host.text = "something else"
        model.useRewrite(.polite)
        XCTAssertEqual(host.text, "something else", "a rewrite never replaces text that changed")
    }
}
