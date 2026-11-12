import XCTest
@testable import Pip

/// The one keyboard check behind onboarding and Home.
@MainActor
final class KeyboardSetupTests: XCTestCase {
    private let ours = "com.orseliyas.pip.keyboard"
    private let system = ["en_US@sw=QWERTY;hw=Automatic", "emoji@sw=Emoji"]
    private let seen = Date(timeIntervalSince1970: 1_800_000_000)

    private func state(_ enabled: [String], _ lastSeen: Date?) -> KeyboardState {
        KeyboardSetup.state(enabled: enabled, lastSeen: lastSeen, keyboardID: ours)
    }

    func testNotInTheListIsNotAdded() {
        XCTAssertEqual(state(system, nil), .notAdded)
    }

    /// Removed in Settings: an old heartbeat does not bring it back.
    func testOldHeartbeatWithoutTheKeyboardIsNotAdded() {
        XCTAssertEqual(state(system, seen), .notAdded)
    }

    /// The bug: Home said "Turn on the keyboard" right after it was turned on, before the keyboard had ever appeared.
    func testAddedBeforeTheKeyboardAppearsNeedsFullAccess() {
        XCTAssertEqual(state(system + [ours], nil), .needsFullAccess)
    }

    func testFirstWithHeartbeatIsReady() {
        XCTAssertEqual(state([ours] + system, seen), .ready)
    }

    /// iOS adds a new keyboard at the bottom of the list, so this is where most owners land.
    func testOnButNotFirstIsNotFirst() {
        XCTAssertEqual(state(system + [ours], seen), .notFirst)
        XCTAssertEqual(state(["en_US@sw=QWERTY;hw=Automatic", ours, "emoji@sw=Emoji"], seen), .notFirst)
    }

    /// Full Access comes before the order hint.
    func testNotFirstWithoutHeartbeatNeedsFullAccess() {
        XCTAssertEqual(state(system + [ours], nil), .needsFullAccess)
    }

    /// Not first is a hint: the app counts the keyboard as on.
    func testOnlyNotFirstAndReadyAreOn() {
        XCTAssertEqual([KeyboardState.notAdded, .needsFullAccess, .notFirst, .ready].map(\.isOn), [false, false, true, true])
        XCTAssertEqual(KeyboardState.notFirst.homeTitle, "Make Pip your first keyboard")
    }

    /// Full Access can be on before the heartbeat lands, so the card asks to finish setup, not to allow it again.
    func testNeedsFullAccessAsksToFinishSetup() {
        XCTAssertEqual(KeyboardState.needsFullAccess.homeTitle, "Finish keyboard setup")
        XCTAssertEqual(KeyboardState.finishSetupLine, "Turn on Allow Full Access, then open Pip once in any chat")
    }

    /// Onboarding's Settings button says where it goes. Reordering lives in Settings › General, which no link can open.
    func testSettingsButtonSaysWhereItGoes() {
        XCTAssertEqual(KeyboardState.needsFullAccess.settingsButton, "Open Pip settings")
        XCTAssertEqual(KeyboardState.notAdded.settingsButton, "Open Pip settings")
        XCTAssertEqual(KeyboardState.notFirst.settingsButton, "Open Settings")
        XCTAssertNil(KeyboardState.ready.settingsButton)
        XCTAssertEqual(KeyboardState.reorderSteps, "Settings › General › Keyboard › Keyboards › Edit, then drag Pip to the top.")
    }

    /// No age limit: a heartbeat from long ago still proves Full Access.
    func testOldHeartbeatIsStillReady() {
        XCTAssertEqual(state([ours], .distantPast), .ready)
    }

    /// iOS shared no list: the heartbeat alone says the keyboard is there, and with no order it counts as first.
    func testEmptyListTrustsTheHeartbeat() {
        XCTAssertEqual(state([], nil), .notAdded)
        XCTAssertEqual(state([], seen), .ready)
    }

    func testAnotherAppsKeyboardIsNotOurs() {
        XCTAssertEqual(state(system + ["com.other.keyboard", ours + "x"], seen), .notAdded)
    }

    /// Back from Settings, a refresh moves the state on, and Home and onboarding read the same object.
    func testRefreshReadsTheLatestValues() {
        var enabled = system
        var lastSeen: Date?
        let setup = KeyboardSetup { (enabled, lastSeen) }
        // The live keyboard id comes from the test host's bundle: the app's id plus ".keyboard".
        XCTAssertEqual(KeyboardSetup.keyboardID, ours)
        XCTAssertEqual(setup.state, .notAdded)
        enabled.append(ours)
        setup.refresh()
        XCTAssertEqual(setup.state, .needsFullAccess)
        lastSeen = seen
        setup.refresh()
        XCTAssertEqual(setup.state, .notFirst)
        enabled = [ours] + system
        setup.refresh()
        XCTAssertEqual(setup.state, .ready)
    }
}

/// The keyboard side of the check: a heartbeat on every appearance, and only with Full Access.
@MainActor
final class KeyboardHeartbeatTests: XCTestCase {
    func testHeartbeatOnEveryAppearanceEvenUnpaired() {
        let clock = FakeClock()
        let store = FakeStore()
        store.signedIn = false
        let deps = KeyboardDeps.fake(api: FakeAPI(), store: store, clock: clock)
        let model = KeyboardModel(deps: deps)
        let host = FakeHost()
        model.host = host
        model.keyboardAppeared()
        let first = deps.store.keyboardLastSeen
        XCTAssertNotNil(first)
        model.keyboardDisappeared()
        clock.advance(60)
        model.keyboardAppeared()
        XCTAssertEqual(deps.store.keyboardLastSeen, first.map { $0.addingTimeInterval(60) })
        model.keyboardDisappeared()
        withExtendedLifetime(host) {}
    }

    func testNoHeartbeatWithoutFullAccess() {
        let deps = KeyboardDeps.fake(api: FakeAPI(), clock: FakeClock())
        let model = KeyboardModel(deps: deps)
        let host = FakeHost()
        host.hasFullAccess = false
        model.host = host
        model.keyboardAppeared()
        XCTAssertNil(deps.store.keyboardLastSeen)
        model.keyboardDisappeared()
        withExtendedLifetime(host) {}
    }
}
