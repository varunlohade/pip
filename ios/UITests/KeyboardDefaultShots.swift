import XCTest

/// "Make it your default": the onboarding step and the Home card in each keyboard state, against `npm run fake`.
/// Each test needs a fresh app: uninstall it (that also removes the keyboard) and reset the simulator keychain.
/// It turns the keyboard on in the simulator's own Settings, so the states come from iOS, not from test switches.
/// Run with TEST_RUNNER_FAKE_URL=http://127.0.0.1:<port> TEST_RUNNER_SHOT_DIR=<dir>
final class KeyboardDefaultShots: XCTestCase {
    private let env = ProcessInfo.processInfo.environment
    private let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    override func setUp() { continueAfterFailure = false }

    private var fake: String { env["FAKE_URL"] ?? "http://127.0.0.1:8799" }

    private func shot(_ name: String) {
        Thread.sleep(forTimeInterval: 0.8)
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let dir = env["SHOT_DIR"] { try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png")) }
    }

    private func id(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@", identifier)).firstMatch
    }

    private func pip(_ query: XCUIElementQuery) -> XCUIElement {
        query.matching(NSPredicate(format: "label BEGINSWITH %@", "Pip")).firstMatch
    }

    private func dismissPrompts(_ app: XCUIApplication) {
        for a in [app, springboard] where a.buttons["Not Now"].waitForExistence(timeout: 2) { a.buttons["Not Now"].tap() }
    }

    /// Settings › General › Keyboard › Keyboards, from the top.
    private func openKeyboards() {
        settings.terminate()
        settings.activate()
        for label in ["General", "Keyboard", "Keyboards"] {
            let cell = settings.cells.staticTexts[label].firstMatch
            if !cell.waitForExistence(timeout: 5) { settings.swipeUp() }
            XCTAssertTrue(cell.waitForExistence(timeout: 5), "no \(label): \(settings.debugDescription)")
            cell.tap()
            // Settings sometimes drops a tap while it is still opening.
            if !settings.navigationBars[label].waitForExistence(timeout: 3), cell.exists { cell.tap() }
        }
    }

    private func addKeyboard() {
        openKeyboards()
        let add = settings.cells["AddNewKeyboard"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 5), settings.debugDescription)
        add.tap()
        let ours = pip(settings.cells.staticTexts)
        XCTAssertTrue(ours.waitForExistence(timeout: 5), settings.debugDescription)
        ours.tap()
    }

    /// iOS ends the app when Full Access changes.
    private func allowFullAccess() {
        openKeyboards()
        let ours = pip(settings.cells.staticTexts)
        XCTAssertTrue(ours.waitForExistence(timeout: 5), settings.debugDescription)
        ours.tap()
        let toggle = settings.switches["Allow Full Access"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), settings.debugDescription)
        // The switch row is wide; its knob sits at the right end.
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        let allow = settings.buttons["Allow"].firstMatch
        XCTAssertTrue(allow.waitForExistence(timeout: 5), settings.debugDescription)
        allow.tap()
    }

    /// Tap the globe key until the Pip keyboard shows, as a person would.
    /// While a third-party keyboard is up, XCUITest often cannot read the app, so the globe is tapped by its place on screen.
    private func switchToPip(_ app: XCUIApplication) {
        id(app, "keyboard.tryit").tap()
        let globe = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.105, dy: 0.952))
        for _ in 0..<3 {
            Thread.sleep(forTimeInterval: 2)
            if id(app, "keyboard.on").exists { return }
            globe.tap()
        }
        Thread.sleep(forTimeInterval: 2)
    }

    private func getStarted(_ app: XCUIApplication) {
        if id(app, "onboarding.calendar.later").waitForExistence(timeout: 3) { id(app, "onboarding.calendar.later").tap() }
        XCTAssertTrue(id(app, "onboarding.start").waitForExistence(timeout: 8), app.debugDescription)
        id(app, "onboarding.start").tap()
        XCTAssertTrue(app.staticTexts["Earned today"].waitForExistence(timeout: 20), app.debugDescription)
        dismissPrompts(app)
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-intro_seen", "YES", "-serverURL", fake]
        app.launch()
        return app
    }

    /// Add, then the default step, then Full Access, then the check when the keyboard really appears.
    func testOnboardingDefaultStep() throws {
        let app = launch()
        try XCTSkipUnless(id(app, "onboarding.later").waitForExistence(timeout: 8), "needs a fresh app: \(app.debugDescription)")
        shot("kb-01-onboarding-add")

        addKeyboard()
        app.activate()
        XCTAssertTrue(id(app, "onboarding.default.later").waitForExistence(timeout: 8), "the default step did not show: \(app.debugDescription)")
        XCTAssertFalse(id(app, "keyboard.on").exists)
        shot("kb-02-onboarding-default-needs-full-access")

        // iOS ends the app on this change, and XCUITest often loses it then, so the next part is its own test.
        allowFullAccess()
    }

    /// Run right after testOnboardingDefaultStep: the keyboard is added with Full Access but has not appeared yet.
    func testOnboardingDefaultStepOn() throws {
        let app = launch()
        XCTAssertTrue(id(app, "keyboard.tryit").waitForExistence(timeout: 8), "run testOnboardingDefaultStep first: \(app.debugDescription)")
        try XCTSkipIf(id(app, "keyboard.on").exists, "the keyboard has appeared already")
        switchToPip(app)
        shot("kb-03-onboarding-default-on")

        // A fresh launch reads the stored heartbeat, so the check proves the keyboard wrote it.
        app.terminate()
        app.launch()
        XCTAssertTrue(id(app, "keyboard.on").waitForExistence(timeout: 8), "no heartbeat: \(app.debugDescription)")
        id(app, "onboarding.default.next").tap()
        getStarted(app)
        // iOS put the new keyboard at the bottom of the list.
        XCTAssertTrue(app.staticTexts["Make Pip your first keyboard"].waitForExistence(timeout: 5), app.debugDescription)
        shot("kb-08-home-not-first")

        // Pip first in the list. The arguments domain stands in for the drag in Settings; the app reads the same preference.
        app.terminate()
        app.launchArguments = ["-AppleKeyboards", "(com.orseliyas.pip.keyboard, \"en_US@sw=QWERTY;hw=Automatic\", \"emoji@sw=Emoji\")"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Keyboard is on"].waitForExistence(timeout: 15), app.debugDescription)
        dismissPrompts(app)
        shot("kb-04-home-ready")
    }

    /// Home right after each change in Settings, with no keyboard use in between.
    func testHomeCardStates() throws {
        let app = launch()
        try XCTSkipUnless(id(app, "onboarding.later").waitForExistence(timeout: 8), "needs a fresh app: \(app.debugDescription)")
        id(app, "onboarding.later").tap()
        getStarted(app)
        XCTAssertTrue(app.staticTexts["Add the Pip keyboard"].waitForExistence(timeout: 5), app.debugDescription)
        shot("kb-05-home-not-added")

        addKeyboard()
        app.activate()
        XCTAssertTrue(app.staticTexts["Finish keyboard setup"].waitForExistence(timeout: 5), "Home did not see the new keyboard: \(app.debugDescription)")
        shot("kb-06-home-needs-full-access")

        id(app, "home.keyboard").tap()
        XCTAssertTrue(id(app, "keyboard.tryit").waitForExistence(timeout: 5), app.debugDescription)
        shot("kb-07-home-steps")
    }
}
