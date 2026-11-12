import XCTest

/// Smart chips in the real Pip keyboard, in the Messages search field, against `npm run fake` (no model call).
/// Grant first: `xcrun simctl privacy <sim> grant calendar com.orseliyas.pip` (and reminders), set the look with
/// `xcrun simctl ui <sim> appearance light|dark`, then run with TEST_RUNNER_FAKE_URL, TEST_RUNNER_SHOT_DIR, TEST_RUNNER_SHOT_PREFIX.
final class SmartChipShots: XCTestCase {
    private let env = ProcessInfo.processInfo.environment
    private let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
    private let messages = XCUIApplication(bundleIdentifier: "com.apple.MobileSMS")

    override func setUp() { continueAfterFailure = false }

    private func shot(_ name: String) {
        Thread.sleep(forTimeInterval: 0.8)
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let dir = env["SHOT_DIR"] { try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent((env["SHOT_PREFIX"] ?? "") + name + ".png")) }
    }

    private func element(_ app: XCUIApplication, _ format: String, _ arg: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: format, arg)).firstMatch
    }

    private func tap(_ app: XCUIApplication, _ labels: [String], timeout: TimeInterval = 8) {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            for l in labels {
                let cell = app.cells.containing(NSPredicate(format: "label == %@", l)).firstMatch
                let e = cell.exists ? cell : element(app, "label == %@", l)
                if e.exists && e.isHittable { e.tap(); Thread.sleep(forTimeInterval: 1.2); return }
            }
            Thread.sleep(forTimeInterval: 0.3)
        } while Date() < deadline
        XCTFail("none of \(labels) found")
    }

    /// Pairs with the fake server once, then turns on the keyboard with Full Access.
    func test1Setup() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-calendarDemo"]
        app.launch()
        // Pairs through the Debug-only pip-dev link, which works from any onboarding step. The system asks to open it first.
        let fake = env["FAKE_URL"] ?? "http://127.0.0.1:8799"
        XCUIDevice.shared.system.open(URL(string: "pip-dev://pair?token=pkd_fake&server=\(fake)")!)
        let open = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Open"]
        if open.waitForExistence(timeout: 4) { open.tap() }
        let mark = element(app, "identifier == %@", "onboarding.mark")
        if mark.waitForExistence(timeout: 6) {
            mark.press(forDuration: 1.3)
            let token = app.secureTextFields["token"]
            XCTAssertTrue(token.waitForExistence(timeout: 5))
            let server = app.textFields.firstMatch
            server.tap()
            server.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 60) + (env["FAKE_URL"] ?? "http://127.0.0.1:8799"))
            token.tap()
            token.typeText("pkd_fake")
            app.buttons["Pair"].tap()
            for id in ["onboarding.later", "onboarding.skip"] {
                let b = element(app, "identifier == %@", id)
                if b.waitForExistence(timeout: 8) { b.tap() }
            }
        }
        XCTAssertTrue(element(app, "identifier == %@", "home.keyboard").waitForExistence(timeout: 15), String(app.debugDescription.suffix(4000)))
        Thread.sleep(forTimeInterval: 3)

        settings.launch()
        tap(settings, ["General"], timeout: 12)
        tap(settings, ["Keyboard"])
        tap(settings, ["Keyboards"])
        let ours = element(settings, "label BEGINSWITH %@", "Pip")
        if !ours.waitForExistence(timeout: 3) {
            tap(settings, ["Add New Keyboard", "Add New Keyboard…"])
            let pick = element(settings, "label BEGINSWITH %@", "Pip")
            if !pick.waitForExistence(timeout: 5) { tap(settings, ["Add New Keyboard", "Add New Keyboard…"]) }
            XCTAssertTrue(pick.waitForExistence(timeout: 5))
            pick.tap()
        }
        XCTAssertTrue(ours.waitForExistence(timeout: 5))
        ours.tap()
        let toggle = settings.switches.firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        if (toggle.value as? String) != "1" {
            toggle.tap()
            if (toggle.value as? String) != "1", toggle.switches.firstMatch.exists { toggle.switches.firstMatch.tap() }
            let allow = settings.alerts.buttons["Allow"]
            if allow.waitForExistence(timeout: 5) { allow.tap() }
        }
        XCTAssertEqual(settings.switches.firstMatch.value as? String, "1")
    }

    /// Opens the search field with our keyboard up and the field empty.
    private func openField() -> XCUIElement {
        messages.terminate()
        messages.launch()
        let search = messages.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 8))
        search.tap()
        // The system keyboard's first-use tip about swipe typing.
        let intro = element(messages, "label == %@", "Continue")
        if intro.waitForExistence(timeout: 2) { intro.tap() }
        let ours = element(messages, "identifier == %@", "pip.more")
        for _ in 0..<5 where !ours.waitForExistence(timeout: 1.5) {
            element(messages, "label == %@", "Next keyboard").tap()
        }
        XCTAssertTrue(ours.exists, "Pip keyboard not shown")
        return search
    }

    /// Pastes the text, then taps our space key, so the keyboard reads it as typed.
    private func enter(_ text: String, in field: XCUIElement) {
        let clear = field.buttons["Clear text"]
        if clear.exists { clear.tap() }
        UIPasteboard.general.string = text
        field.press(forDuration: 1.0)
        let paste = element(messages, "label == %@", "Paste")
        XCTAssertTrue(paste.waitForExistence(timeout: 4), "no Paste menu")
        paste.tap()
        let allow = messages.alerts.buttons["Allow Paste"]
        if allow.waitForExistence(timeout: 1) { allow.tap() }
        // The paste is only a fast way to type; with the copy gone, the bar shows what typing gives.
        UIPasteboard.general.items = []
        Thread.sleep(forTimeInterval: 0.3)
        element(messages, "identifier == %@", "space").tap()
    }

    func test2Shots() {
        let field = openField()
        Thread.sleep(forTimeInterval: 1.5)
        shot("00-empty-ready-chips")

        let rows: [(name: String, text: String, chip: String?)] = [
            ("01-meeting", "meeting with Ana tomorrow 3pm", "chip.smart.event"),
            ("02-dentist", "dentist friday 10am", "chip.smart.event"),
            ("03-call-supplier", "call supplier at 5", "chip.smart.reminder"),
            ("04-oven", "remind me in 20 min to check oven", "chip.smart.reminder"),
            ("05-shampoo", "need to buy shampoo", "chip.smart.note"),
            ("07-lol-ok", "lol ok", nil),
        ]
        for row in rows {
            enter(row.text, in: field)
            if let id = row.chip {
                let chip = element(messages, "identifier == %@", id)
                if !chip.waitForExistence(timeout: 8) { shot(row.name + "-FAIL"); print("FIELD", field.value ?? "") }
                XCTAssertTrue(chip.exists, "\(row.text): no \(id)")
                shot(row.name)
                if ["01-meeting", "03-call-supplier", "05-shampoo"].contains(row.name) {
                    chip.tap()
                    XCTAssertTrue(element(messages, "identifier == %@", "chip.added").waitForExistence(timeout: 3), "\(row.text): no added line")
                    shot(row.name + "-added")
                    element(messages, "identifier == %@", "chip.undo").tap()
                    Thread.sleep(forTimeInterval: 0.5)
                }
            } else {
                Thread.sleep(forTimeInterval: 1.5)
                shot(row.name)
            }
        }
    }
}
