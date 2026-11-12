import XCTest

/// A fresh install, start to finish, for the screen recording: the whole intro, the keyboard turned on in Settings,
/// Get started, then Home. It runs against `npm run fake`: no model call.
/// Run on a simulator with no Pip installed, with TEST_RUNNER_FAKE_URL=http://127.0.0.1:<port>.
final class OnboardingWalkthroughVideo: XCTestCase {
    private let env = ProcessInfo.processInfo.environment
    private let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    override func setUp() { continueAfterFailure = false }

    private func find(_ app: XCUIApplication, _ format: String, _ arg: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: format, arg)).firstMatch
    }

    private func id(_ app: XCUIApplication, _ identifier: String) -> XCUIElement { find(app, "identifier == %@", identifier) }

    private func pause(_ seconds: TimeInterval = 1.2) { Thread.sleep(forTimeInterval: seconds) }

    private func dismissPrompts(_ app: XCUIApplication) {
        for a in [app, springboard] where a.buttons["Not Now"].waitForExistence(timeout: 2) { a.buttons["Not Now"].tap() }
    }

    private func turnOn(_ toggle: XCUIElement) {
        guard (toggle.value as? String) != "1" else { return }
        toggle.tap()
        if (toggle.value as? String) != "1", toggle.switches.firstMatch.exists { toggle.switches.firstMatch.tap() }
        let allow = settings.alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 4) { pause(0.8); allow.tap() }
    }

    /// Taps the first Settings row that shows one of `labels`, once it can be hit.
    private func tapRow(_ labels: [String], timeout: TimeInterval = 6) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            for l in labels {
                let cell = settings.cells.containing(NSPredicate(format: "label == %@", l)).firstMatch
                let e = cell.exists ? cell : find(settings, "label == %@", l)
                if e.exists && e.isHittable { pause(0.8); e.tap(); pause(0.8); return true }
            }
            pause(0.3)
        } while Date() < deadline
        return false
    }

    func testWalkthrough() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-calendarDemo", "-serverURL", env["FAKE_URL"] ?? "http://127.0.0.1:8799"]
        app.launch()

        // 1. The intro plays by itself: eight scenes, about 3 s each.
        XCTAssertTrue(id(app, "onboarding.skip").waitForExistence(timeout: 10), "a fresh install starts at the intro")

        // 2. Enable the keyboard in Settings, the way the step says.
        let start = id(app, "onboarding.start")
        let deadline = Date().addingTimeInterval(60)
        while !(id(app, "onboarding.step.2").exists || start.exists), Date() < deadline { pause(0.3) }
        // A phone that already has the keyboard goes straight to Get started.
        if id(app, "onboarding.step.2").exists {
            pause(2)
            app.buttons["Open Settings"].tap()
            XCTAssertTrue(settings.wait(for: .runningForeground, timeout: 10))
            let keyboards = find(settings, "label BEGINSWITH %@", "Keyboards")
            if keyboards.waitForExistence(timeout: 4) {
                // The app's own Settings page: Keyboards › Pip Keyboard, Allow Full Access.
                pause()
                keyboards.tap()
                let ours = settings.switches.matching(NSPredicate(format: "label BEGINSWITH %@", "Pip")).firstMatch
                XCTAssertTrue(ours.waitForExistence(timeout: 5), settings.debugDescription)
                pause()
                turnOn(ours)
            } else {
                // A fresh simulator opens Settings at the top: General › Keyboard › Keyboards › Add New Keyboard.
                settings.launch()
                XCTAssertTrue(tapRow(["General"], timeout: 10), settings.debugDescription)
                XCTAssertTrue(tapRow(["Keyboard"]), settings.debugDescription)
                XCTAssertTrue(tapRow(["Keyboards"]), settings.debugDescription)
                let add = find(settings, "label BEGINSWITH %@", "Add New Keyboard")
                XCTAssertTrue(add.waitForExistence(timeout: 5), settings.debugDescription)
                pause(0.8)
                add.tap()
                let pick = find(settings, "label BEGINSWITH %@", "Pip")
                if !pick.waitForExistence(timeout: 5) { add.tap() }
                XCTAssertTrue(pick.waitForExistence(timeout: 5), settings.debugDescription)
                pause(0.8)
                pick.tap()
                let row = find(settings, "label BEGINSWITH %@", "Pip")
                XCTAssertTrue(row.waitForExistence(timeout: 5), settings.debugDescription)
                pause(0.8)
                row.tap()
            }
            let full = settings.switches.firstMatch
            XCTAssertTrue(full.waitForExistence(timeout: 5), settings.debugDescription)
            pause()
            turnOn(full)
            pause(1.5)
            app.activate()
        }

        // 3. Get started: one tap, no sign-in. Then Home.
        // The app moves on by itself when it sees the keyboard. If iOS has not told it yet, "Not now" goes on.
        if !start.waitForExistence(timeout: 6), id(app, "onboarding.later").exists { id(app, "onboarding.later").tap() }
        if id(app, "onboarding.calendar.later").waitForExistence(timeout: 3) { id(app, "onboarding.calendar.later").tap() }
        XCTAssertTrue(start.waitForExistence(timeout: 10), app.debugDescription)
        pause(2)
        start.tap()
        XCTAssertTrue(app.staticTexts["Earned today"].waitForExistence(timeout: 20), app.debugDescription)
        dismissPrompts(app)
        _ = id(app, "home.brief").waitForExistence(timeout: 10)
        pause(3)
        app.swipeUp()
        pause(3)
        app.swipeDown()
        pause(2)
    }
}
