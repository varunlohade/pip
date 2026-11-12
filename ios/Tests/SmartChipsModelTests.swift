import XCTest
@testable import Pip

/// Smart chips in the keyboard, with a fake calendar and reminders. No server call unless the text is a "maybe an action" sentence.
@MainActor
final class SmartChipsModelTests: XCTestCase {
    private var host: FakeHost!
    private var api: FakeAPI!
    private var clock: FakeClock!
    private var store: FakeStore!
    private var writer: FakeWriter!
    private var model: KeyboardModel!

    override func setUp() async throws {
        host = FakeHost()
        api = FakeAPI()
        clock = FakeClock()
        store = FakeStore()
        writer = FakeWriter()
        model = KeyboardModel(deps: .fake(api: api, store: store, clock: clock, writer: writer))
        model.host = host
        model.keyboardAppeared()
    }

    override func tearDown() async throws {
        model.keyboardDisappeared()
        model = nil
    }

    private func until(_ what: String, _ cond: () -> Bool) async {
        for _ in 0..<500 where !cond() { await Task.yield() }
        XCTAssertTrue(cond(), "timed out waiting for \(what)")
    }

    /// Types `text` and lets the pause run out.
    private func typeAndPause(_ text: String) async {
        host.text = text
        model.textChanged()
        await until("pause sleep") { clock.sleeping > 0 }
        clock.advance(SuggestPolicy.debounce.seconds)
    }

    private func item(_ id: String) -> BarItems.Item? { model.barItems.first { $0.id == id } }

    func testTapAddsTheReminderAndUndoRemovesIt() async {
        await typeAndPause("call supplier at 5")
        await until("reminder chip") { item("smart.reminder") != nil }
        let chip = item("smart.reminder")!
        XCTAssertEqual(chip.trigger, "at 5")
        XCTAssertTrue(chip.title.hasPrefix("Remind me "), chip.title)
        XCTAssertEqual(api.calls, [], "a clear match costs no server call")

        model.perform(chip.action!)
        XCTAssertEqual(writer.reminders.values.map(\.title), ["Call supplier"])
        XCTAssertEqual(model.barItems.map(\.id), ["added", "undo"])
        XCTAssertTrue(model.barItems[0].title.hasPrefix("Reminder set \u{00B7} "), model.barItems[0].title)

        model.perform(.undoSmart)
        XCTAssertTrue(writer.reminders.isEmpty, "Undo deletes the reminder")
        XCTAssertNotNil(item("smart.reminder"), "the chip comes back after Undo")
    }

    func testEventAddsOnceAndTheAddedLineGoesAfterTheUndoWindow() async {
        await typeAndPause("dinner with Ana at 8")
        await until("event chip") { item("smart.event") != nil }
        model.perform(item("smart.event")!.action!)
        XCTAssertEqual(writer.events.values.map(\.title), ["Dinner with Ana"])
        XCTAssertTrue(model.barItems[0].title.hasPrefix("Added to Calendar \u{00B7} "))
        XCTAssertNil(item("smart.event"), "an added chip does not come back for the same text")
        await until("undo timer") { clock.sleeping > 0 }
        clock.advance(KeyboardModel.undoWindow.seconds)
        await until("added line gone") { model.added == nil }
        XCTAssertEqual(writer.events.count, 1)
    }

    func testNoPermissionShowsTheAllowLineAndTapDoesNothing() async {
        writer.granted = [.notes]
        await typeAndPause("call supplier at 5")
        await until("allow line") { item("allow.Reminders") != nil }
        let allow = item("allow.Reminders")!
        XCTAssertEqual(allow.title, "Allow Reminders in \(AppConfig.displayName)")
        XCTAssertNil(allow.action, "a keyboard cannot open the app's permission prompt")
        model.tapSmart(model.smart[0])
        XCTAssertTrue(writer.reminders.isEmpty)
    }

    func testNoteGoesToTheNotesStoreAndUndoTakesItOut() async {
        await typeAndPause("note: gate code is 4521")
        await until("note chip") { item("smart.note") != nil }
        model.perform(item("smart.note")!.action!)
        XCTAssertEqual(store.notes.first?.text, "Gate code is 4521")
        model.perform(.undoSmart)
        XCTAssertFalse(store.notes.contains { $0.text == "Gate code is 4521" })
    }

    func testPlainChatCostsNothingAndShowsNothing() async {
        host.text = "lol ok see you"
        model.textChanged()
        clock.advance(1)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(api.calls, [])
        XCTAssertTrue(model.smart.isEmpty)
    }

    func testMaybeSentenceAsksOnceAndShowsTheServersDeviceChip() async {
        api.suggestReply = SuggestResponse(chips: [Chip(kind: "followup", label: "Follow up", payload: ["title": .string("Follow up with Ana")],
                                                        needs_confirm: false, trigger: "Ana")], intent: "followup", timings: nil)
        await typeAndPause("can we sort out Ana's thing")
        await until("follow-up chip") { item("smart.reminder") != nil }
        XCTAssertEqual(api.suggested.map(\.text), ["can we sort out Ana's thing"])
        XCTAssertEqual(item("smart.reminder")?.trigger, "Ana")

        host.text = "can we sort out Ana's thing soon"
        model.textChanged()
        clock.advance(SuggestPolicy.debounce.seconds)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(api.calls, ["suggest"], "the same sentence never goes twice")
        XCTAssertNotNil(item("smart.reminder"), "the server's chip stays while the sentence goes on")
    }

    func testEmptyFieldShowsReadyChipsFromTheSnapshot() async {
        XCTAssertEqual(model.barItems.map(\.title), ["Notes"])
        let now = clock.now
        store.appointments = [Appointment(start: now + 3600, end: now + 7200, title: "Dentist")]
        host.text = "hi"
        model.textChanged()
        host.text = ""
        model.textChanged()
        XCTAssertEqual(model.barItems.map(\.id), ["next", "today", "notes"], "an empty field after a send reloads the snapshot")
        XCTAssertEqual(model.barItems.first?.detail, "Dentist")
        XCTAssertEqual(api.calls, [])
    }

    func testTodayChipListsTheEvents() async {
        let now = clock.now
        store.appointments = [Appointment(start: now - 7200, end: now - 3600, title: "Dentist")]
        host.text = "hi"
        model.textChanged()
        host.text = ""
        model.textChanged()
        model.perform(item("today")!.action!)
        guard case .done(let line) = model.bar else { return XCTFail("expected a line, got \(model.bar)") }
        XCTAssertTrue(line.hasSuffix("Dentist"), line)
    }
}
