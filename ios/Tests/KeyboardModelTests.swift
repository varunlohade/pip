import XCTest
@testable import Pip

@MainActor
final class KeyboardModelTests: XCTestCase {
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

    /// Taps the real keys, switching layouts and shift the way a person would. One second between taps.
    private func type(_ s: String) {
        func keys() -> [KeyCap] { KeyboardGeometry.keys(layout: model.layout, width: 390, globe: false, currency: "$") }
        func tap(_ id: String) {
            guard let key = keys().first(where: { $0.id == id }) else { return XCTFail("no key \(id) in \(model.layout)") }
            clock.advance(1)
            model.activate(key)
        }
        func charKey(_ c: String) -> KeyCap? { keys().first { $0.kind == .char(c) } }

        for ch in s {
            if ch == " " { tap("space"); continue }
            let c = String(ch).lowercased()
            if charKey(c) == nil {
                if model.layout != .letters { tap("mode") }
                if charKey(c) == nil { tap("mode") }
                if charKey(c) == nil { tap("mode.alt") }
            }
            guard let key = charKey(c) else { return XCTFail("cannot type \(ch)") }
            if model.layout == .letters, ch.isUppercase != (model.shift != .off) { tap("shift") }
            clock.advance(1)
            model.activate(key)
        }
    }

    private func until(_ what: String, _ cond: () -> Bool) async {
        for _ in 0..<500 where !cond() { await Task.yield() }
        XCTAssertTrue(cond(), "timed out waiting for \(what)")
    }

    /// Lets the debounce run out: waits for the suggest task to fall asleep, then moves the clock past it.
    private func passDebounce() async {
        await until("debounce sleep") { clock.sleeping > 0 }
        clock.advance(ChipTiming.routePauseMidWord.seconds)
    }

    func testOneCharacterSendsNothing() async {
        type("h")
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(api.calls, [])
        XCTAssertEqual(clock.sleeps, [])
    }

    func testPlainChatSendsNoSuggest() async {
        type("i can do teh job")
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(api.calls, [])
        XCTAssertFalse(clock.sleeps.contains(SuggestPolicy.debounce), "no server ask is even scheduled: \(clock.sleeps)")
    }

    func testNoCapitalAfterTheShortcutPrefix() {
        func tap(_ id: String) {
            let keys = KeyboardGeometry.keys(layout: model.layout, width: 390, globe: false, currency: "$")
            guard let key = keys.first(where: { $0.id == id || $0.kind == .char(id) }) else { return XCTFail("no key \(id) in \(model.layout)") }
            clock.advance(1)
            model.activate(key)
        }
        tap("mode"); tap(";"); tap("mode"); tap("f"); tap("i"); tap("x")
        XCTAssertEqual(host.text, ";fix")
    }

    func testCardNumberSendsNothing() async {
        type("my card 4242 4242 4242 4242")
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(api.calls, [])
    }

    func testADeviceReplyForOldTextIsDropped() async {
        let event = Chip(kind: "event", label: "Add to calendar", payload: ["title": .string("Ana's thing")], needs_confirm: false)
        api.routeReply = RouteResponse(label: "calendar_event", confidence: 0.9, chips: [event])
        host.text = "can we do Ana's thing Friday"
        model.textChanged()
        api.duringRoute = { [unowned self] in self.host.text += " or not" }
        await passDebounce()
        await until("route") { api.calls == ["route"] }
        for _ in 0..<50 { await Task.yield() }
        XCTAssertFalse(model.smart.contains { $0.id == "smart.event" }, "the text moved on, so the chip is not shown")
    }

    func testAMemoryWarningMidLoadNeverStartsASecondLanguageLoad() async throws {
        // Start from no model and no load running.
        KeyboardModel.loadLanguage()
        for _ in 0..<1000 where KeyboardModel.language == nil { try await Task.sleep(for: .milliseconds(10)) }
        model.releaseCaches()
        XCTAssertNil(KeyboardModel.language)

        let loads = LoadCounter()
        let gate = DispatchSemaphore(value: 0)
        KeyboardModel.loadLanguage { loads.add(); gate.wait(); return LanguageModel.bundled() }
        model.releaseCaches()  // a memory warning while the model loads
        KeyboardModel.loadLanguage { loads.add(); return LanguageModel.bundled() }  // the keyboard appears again
        gate.signal()
        for _ in 0..<1000 where KeyboardModel.language == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(KeyboardModel.language, "the running load still lands, since the keyboard asked again")
        XCTAssertEqual(loads.count, 1, "one load, not two")
    }
}

private final class LoadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func add() { lock.withLock { n += 1 } }
    var count: Int { lock.withLock { n } }
}
