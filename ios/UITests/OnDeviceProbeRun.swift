import XCTest

/// Spike only (branch `ondevice`): turns the Pip keyboard on in Settings, opens the probe screen and switches to Pip,
/// so the keyboard runs OnDeviceProbe. Run without Full Access first, then testWithFullAccess.
/// Read the results with: log show --predicate 'subsystem == "pip.ondevice"'
final class OnDeviceProbeRun: XCTestCase {
    private let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    override func setUp() { continueAfterFailure = false }

    private func pip(_ query: XCUIElementQuery) -> XCUIElement {
        query.matching(NSPredicate(format: "label BEGINSWITH %@", "Pip")).firstMatch
    }

    private func openKeyboards() {
        settings.terminate()
        settings.activate()
        for label in ["General", "Keyboard", "Keyboards"] {
            let cell = settings.cells.staticTexts[label].firstMatch
            if !cell.waitForExistence(timeout: 5) { settings.swipeUp() }
            XCTAssertTrue(cell.waitForExistence(timeout: 5), "no \(label): \(settings.debugDescription)")
            cell.tap()
            if !settings.navigationBars[label].waitForExistence(timeout: 3), cell.exists { cell.tap() }
        }
    }

    private func addKeyboardIfNeeded() {
        openKeyboards()
        if pip(settings.cells.staticTexts).waitForExistence(timeout: 2) { return }
        settings.cells["AddNewKeyboard"].firstMatch.tap()
        let ours = pip(settings.cells.staticTexts)
        XCTAssertTrue(ours.waitForExistence(timeout: 5), settings.debugDescription)
        ours.tap()
    }

    /// Opens the probe screen, waits for the app probe, then taps the globe until the keyboard writes " started",
    /// and waits for " done".
    private func runKeyboardProbe() {
        let app = XCUIApplication()
        app.launchArguments = ["-ondeviceProbe", "YES"]
        app.launch()
        let field = app.textFields["probe.field"]
        XCTAssertTrue(app.staticTexts["App probe done"].waitForExistence(timeout: 180), app.debugDescription)
        field.tap()
        let globe = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.105, dy: 0.952))
        var started = false
        for _ in 0..<4 {
            Thread.sleep(forTimeInterval: 3)
            if (field.value as? String ?? "").contains("started") { started = true; break }
            globe.tap()
        }
        XCTAssertTrue(started, "the keyboard never ran the probe: \(field.value ?? "nil")")
        let done = NSPredicate(format: "value CONTAINS %@", "done")
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: done, evaluatedWith: field)], timeout: 240), .completed, "\(field.value ?? "nil")")
    }

    func testWithoutFullAccess() {
        addKeyboardIfNeeded()
        runKeyboardProbe()
    }

    func testWithFullAccess() {
        openKeyboards()
        let ours = pip(settings.cells.staticTexts)
        XCTAssertTrue(ours.waitForExistence(timeout: 5), settings.debugDescription)
        ours.tap()
        let toggle = settings.switches["Allow Full Access"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), settings.debugDescription)
        if (toggle.value as? String) != "1" {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
            let allow = settings.buttons["Allow"].firstMatch
            XCTAssertTrue(allow.waitForExistence(timeout: 5), settings.debugDescription)
            allow.tap()
        }
        runKeyboardProbe()
    }
}
