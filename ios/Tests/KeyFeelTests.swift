import XCTest
@testable import Pip

/// How the keys feel under a finger: haptics, the space-bar trackpad, long-press and delete repeat. Fake clock throughout.
@MainActor
final class KeyFeelTests: XCTestCase {
    private var host: FakeHost!
    private var clock: FakeClock!
    private var store: FakeStore!
    private var spy: HapticSpy!
    private var model: KeyboardModel!
    private let keys = KeyboardGeometry.keys(layout: .letters, width: 390, globe: false, currency: "$")
    private var fingers: [NSObject] = []

    override func setUp() async throws {
        host = FakeHost()
        host.autocapitalization = .none
        clock = FakeClock()
        store = FakeStore()
        spy = HapticSpy()
        model = KeyboardModel(deps: .fake(api: FakeAPI(), store: store, clock: clock, haptics: spy))
        model.host = host
        model.keyboardAppeared()
    }

    override func tearDown() async throws {
        model.keyboardDisappeared()
        model = nil
    }

    private func key(_ id: String) -> KeyCap { keys.first { $0.id == id || $0.kind == .char(id) }! }
    private func finger() -> ObjectIdentifier { let f = NSObject(); fingers.append(f); return ObjectIdentifier(f) }
    private func mid(_ k: KeyCap) -> CGPoint { CGPoint(x: k.frame.midX, y: k.frame.midY) }

    private func until(_ what: String, _ cond: () -> Bool) async {
        for _ in 0..<500 where !cond() { await Task.yield() }
        XCTAssertTrue(cond(), "timed out waiting for \(what)")
    }

    /// Moves the fake clock forward in 1 ms steps, letting every sleeper wake on time.
    private func run(for seconds: TimeInterval) async {
        for _ in 0..<Int((seconds * 1000).rounded()) {
            clock.advance(0.001)
            for _ in 0..<4 { await Task.yield() }
        }
    }

    // MARK: haptics

    func testALightTapOnEveryTouchDown() {
        for c in ["h", "i"] { let f = finger(); model.touchBegan(f, key(c), at: mid(key(c))); model.touchEnded(f) }
        XCTAssertEqual(spy.taps, [.light, .light])
        XCTAssertGreaterThan(spy.prepared, 0, "the engine is kept ready from the moment the keyboard appears")
    }

    func testTheSwitchOrNoFullAccessMeansNoHaptic() {
        store.keyHaptics = false
        model.keyboardAppeared()
        let f = finger(); model.touchBegan(f, key("h"), at: mid(key("h"))); model.touchEnded(f)
        store.keyHaptics = true
        host.hasFullAccess = false
        model.keyboardAppeared()
        let g = finger(); model.touchBegan(g, key("h"), at: mid(key("h"))); model.touchEnded(g)
        XCTAssertEqual(spy.taps, [])
        XCTAssertEqual(host.text, "hh")
    }

    // MARK: space-bar trackpad

    func testASlowSlideMovesOneCharacterPerNinePointsAndTypesNoSpace() {
        host.text = "see you soon"
        let f = finger(), space = key("space")
        model.touchBegan(f, space, at: CGPoint(x: 200, y: space.frame.midY))
        clock.advance(0.5)
        model.touchMoved(f, space, at: CGPoint(x: 195, y: space.frame.midY))
        XCTAssertFalse(model.trackpad, "under 10 pt is still a tap")
        clock.advance(0.5)
        model.touchMoved(f, space, at: CGPoint(x: 190, y: space.frame.midY))
        XCTAssertTrue(model.trackpad)
        clock.advance(0.5)
        model.touchMoved(f, key("k.0.q"), at: CGPoint(x: 155, y: 120))
        model.touchEnded(f)
        XCTAssertEqual(host.cursorMoves.reduce(0, +), -5)
        XCTAssertEqual(host.text + host.after, "see you soon")
        XCTAssertEqual(host.after, " soon")
        XCTAssertFalse(model.trackpad)
        XCTAssertEqual(spy.taps, [.light, .light], "touch-down, then the slide starts")
    }

    func testAFastFlickGoesFurther() {
        host.text = String(repeating: "a", count: 60)
        let f = finger(), space = key("space")
        model.touchBegan(f, space, at: CGPoint(x: 200, y: space.frame.midY))
        clock.advance(0.01)
        model.touchMoved(f, space, at: CGPoint(x: 155, y: space.frame.midY))
        model.touchEnded(f)
        XCTAssertEqual(host.cursorMoves.reduce(0, +), -12, "45 pt at 4500 pt/s is 2.5 x 5 steps")
    }

    func testTheCursorMovesByWholeCharacters() {
        host.text = "ok 👍🏽"
        let f = finger(), space = key("space")
        model.touchBegan(f, space, at: CGPoint(x: 200, y: space.frame.midY))
        clock.advance(1)
        model.touchMoved(f, space, at: CGPoint(x: 190, y: space.frame.midY))
        model.touchEnded(f)
        XCTAssertEqual(host.cursorMoves, [-4], "the emoji with its skin tone is one step")
        XCTAssertEqual(host.after, "👍🏽")
    }

    func testATapOnSpaceStillTypesASpace() {
        host.text = "see"
        let f = finger(), space = key("space")
        model.touchBegan(f, space, at: mid(space))
        model.touchEnded(f)
        XCTAssertEqual(host.text, "see ")
        XCTAssertEqual(host.cursorMoves, [])
    }

    // MARK: long-press

    func testHoldingALetterOpensItsAccentsAndTheLiftTypesThePick() async {
        let f = finger(), e = key("e")
        model.touchBegan(f, e, at: mid(e))
        await until("hold timer") { clock.sleeping > 0 }
        clock.advance(0.35)
        await until("accents") { model.accents != nil }
        let popup = try! XCTUnwrap(model.accents)
        XCTAssertNil(model.calloutKeyID, "the balloon gives way to the popup")
        XCTAssertEqual(spy.taps, [.light, .medium])
        let i = try! XCTUnwrap(popup.options.firstIndex(of: "é"))
        model.touchMoved(f, e, at: CGPoint(x: popup.cells[i].midX, y: popup.cells[i].midY))
        model.touchEnded(f)
        XCTAssertEqual(host.text, "é")
        XCTAssertNil(model.accents)
        for c in popup.cells { XCTAssertTrue(CGRect(x: 0, y: 0, width: 390, height: 400).contains(c), "inside the keyboard") }
    }

    func testAShortHoldTypesTheLetter() async {
        let f = finger(), e = key("e")
        model.touchBegan(f, e, at: mid(e))
        await until("hold timer") { clock.sleeping > 0 }
        clock.advance(0.2)
        model.touchEnded(f)
        XCTAssertEqual(host.text, "e")
        XCTAssertNil(model.accents)
    }

    func testHoldingReturnTypesANewLineOnceEvenInASendField() async {
        host.returnKeyType = .send
        host.text = "hi"
        model.textChanged()
        let f = finger(), ret = key("return")
        model.touchBegan(f, ret, at: mid(ret))
        await until("hold timer") { clock.sleeping > 0 }
        clock.advance(0.45)
        await until("new line") { host.text == "hi\n" }
        XCTAssertEqual(spy.taps, [.light, .medium])
        model.touchEnded(f)
        XCTAssertEqual(host.text, "hi\n", "the lift adds nothing")
    }

    // MARK: delete repeat

    func testDeleteRepeatsAfter450msAt90msThenAt45ms() async {
        host.text = String(repeating: "x", count: 100)
        let f = finger(), del = key("delete")
        model.touchBegan(f, del, at: mid(del))
        XCTAssertEqual(host.text.count, 99, "the first character goes on touch-down")
        await run(for: 0.44)
        XCTAssertEqual(host.text.count, 99)
        await run(for: 0.02)
        XCTAssertEqual(host.text.count, 98, "repeat starts at 450 ms")
        await run(for: 0.54)
        XCTAssertGreaterThanOrEqual(100 - host.text.count, 6, "a 1 s hold deletes at least 6")
        // 18 slow repeats in all, then 45 ms each.
        await run(for: 0.45 + 17 * 0.09 - 1.0 + 0.005)
        let atSwitch = host.text.count
        XCTAssertEqual(100 - atSwitch, 19)
        await run(for: 0.45)
        XCTAssertEqual(atSwitch - host.text.count, 10, "45 ms a character after 18")
        model.touchMoved(f, del, at: CGPoint(x: del.frame.midX, y: del.frame.minY - 30))
        let stopped = host.text.count
        await run(for: 0.3)
        XCTAssertEqual(host.text.count, stopped, "sliding off the key stops the repeat")
        model.touchEnded(f)
    }

    func testASmallWobbleOnDeleteKeepsRepeating() async {
        host.text = String(repeating: "x", count: 30)
        let f = finger(), del = key("delete")
        model.touchBegan(f, del, at: mid(del))
        model.touchMoved(f, del, at: CGPoint(x: del.frame.maxX + 10, y: del.frame.midY))
        await run(for: 0.6)
        XCTAssertEqual(host.text.count, 27)
        model.touchEnded(f)
    }
}
