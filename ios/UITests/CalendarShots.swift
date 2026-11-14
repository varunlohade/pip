import XCTest

/// The calendar panel (design C) in the real Pip keyboard, in a Messages chat, against `npm run fake` (no model call).
/// Grant first: `xcrun simctl privacy <sim> grant calendar com.orseliyas.pip` (and reminders). test1Setup pairs, seeds the
/// mock's day with "-calendarWeekDemo" and turns the keyboard on with Full Access. Set the look with
/// `xcrun simctl ui <sim> appearance light|dark`, then run with TEST_RUNNER_FAKE_URL, TEST_RUNNER_SHOT_DIR, TEST_RUNNER_SHOT_PREFIX.
final class CalendarShots: XCTestCase {
    private let env = ProcessInfo.processInfo.environment
    private let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
    private let messages = XCUIApplication(bundleIdentifier: "com.apple.MobileSMS")

    override func setUp() { continueAfterFailure = false }

    private func shot(_ name: String) {
        Thread.sleep(forTimeInterval: 0.8)
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let dir = env["SHOT_DIR"] { try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent((env["SHOT_PREFIX"] ?? "calendar-") + name + ".png")) }
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@", id)).firstMatch
    }

    private func label(_ app: XCUIApplication, _ l: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", l)).firstMatch
    }

    private func tap(_ app: XCUIApplication, _ labels: [String], timeout: TimeInterval = 8) {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            for l in labels {
                let cell = app.cells.containing(NSPredicate(format: "label == %@", l)).firstMatch
                let e = cell.exists ? cell : label(app, l)
                if e.exists && e.isHittable { e.tap(); Thread.sleep(forTimeInterval: 1.2); return }
            }
            Thread.sleep(forTimeInterval: 0.3)
        } while Date() < deadline
        XCTFail("none of \(labels) found")
    }

    /// Pairs with the fake server, seeds the calendar, then turns on the keyboard with Full Access.
    func test1Setup() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-calendarWeekDemo"]
        app.launch()
        let fake = env["FAKE_URL"] ?? "http://127.0.0.1:8799"
        XCUIDevice.shared.system.open(URL(string: "pip-dev://pair?token=pkd_fake&server=\(fake)")!)
        let open = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Open"]
        if open.waitForExistence(timeout: 4) { open.tap() }
        for id in ["onboarding.later", "onboarding.skip"] {
            let b = element(app, id)
            if b.waitForExistence(timeout: 8) { b.tap() }
        }
        XCTAssertTrue(element(app, "home.keyboard").waitForExistence(timeout: 15), String(app.debugDescription.suffix(4000)))
        // Home reads the calendar on appear; that seeds the demo events once.
        Thread.sleep(forTimeInterval: 3)

        settings.launch()
        tap(settings, ["General"], timeout: 12)
        tap(settings, ["Keyboard"])
        tap(settings, ["Keyboards"])
        let ours = settings.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Pip")).firstMatch
        if !ours.waitForExistence(timeout: 3) {
            tap(settings, ["Add New Keyboard", "Add New Keyboard…"])
            let pick = settings.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Pip")).firstMatch
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

    private func paste(_ text: String, into field: XCUIElement) {
        UIPasteboard.general.string = text
        field.press(forDuration: 1.0)
        let paste = label(messages, "Paste")
        XCTAssertTrue(paste.waitForExistence(timeout: 4), "no Paste menu")
        paste.tap()
        let allow = messages.alerts.buttons["Allow Paste"]
        if allow.waitForExistence(timeout: 1) { allow.tap() }
        Thread.sleep(forTimeInterval: 0.6)
        UIPasteboard.general.items = []
    }

    /// A real chat: the first conversation in Messages, or a new one, with the Pip keyboard up in the message box.
    private func openField() -> XCUIElement {
        messages.terminate()
        messages.launch()
        let chat = messages.cells.firstMatch
        if chat.waitForExistence(timeout: 6) {
            chat.tap()
        } else {
            let compose = messages.descendants(matching: .any).matching(NSPredicate(format: "label IN {'Compose', 'New Message'}")).firstMatch
            XCTAssertTrue(compose.waitForExistence(timeout: 4), "no conversation and no Compose")
            compose.tap()
            let to = messages.textFields.firstMatch
            XCTAssertTrue(to.waitForExistence(timeout: 4), "no To field")
            paste("555-0100", into: to)
        }
        let body = messages.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == 'messageBodyField' OR placeholderValue IN {'iMessage', 'Text Message', 'Message'} OR label IN {'iMessage', 'Text Message', 'Message'}")).firstMatch
        if body.waitForExistence(timeout: 6) { body.tap() } else { messages.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.945)).tap() }
        XCTAssertTrue(body.exists, "no message box")
        let intro = label(messages, "Continue")
        if intro.waitForExistence(timeout: 2) { intro.tap() }
        let ours = element(messages, "pip.more")
        for _ in 0..<8 where !ours.waitForExistence(timeout: 2.5) {
            let next = label(messages, "Next keyboard")
            if next.exists { next.tap(); continue }
            // No keys up (the message box sits at the bottom): focus it again.
            if body.frame.maxY > messages.frame.height * 0.85 { body.tap(); continue }
            // iOS 26 puts the globe under the keys, outside the app's tree: tap where it sits.
            messages.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.963)).tap()
        }
        if !ours.exists { print("NO_PIP", messages.debugDescription.suffix(5000)) }
        XCTAssertTrue(ours.exists, "Pip keyboard not shown")
        return body
    }

    private func clear(_ field: XCUIElement) {
        let delete = element(messages, "delete")
        for _ in 0..<6 where !((field.value as? String) ?? "").isEmpty && (field.value as? String) != field.placeholderValue {
            delete.press(forDuration: 2.5)
        }
    }

    private func wait(_ id: String) -> XCUIElement {
        let e = element(messages, id)
        XCTAssertTrue(e.waitForExistence(timeout: 6), "no \(id): \(messages.debugDescription.suffix(3000))")
        return e
    }

    func test2Shots() {
        let field = openField()
        clear(field)

        wait("calendar.toggle").tap()
        _ = wait("calendar.dayCard")
        shot("month")

        wait("calendar.share").tap()
        _ = wait("calendar.draft")
        shot("share")
        wait("calendar.insert").tap()
        shot("share-inserted")
        clear(field)

        // Tomorrow's seeded lunch (12-2), so the clash shows at any hour of the day.
        paste("coffee with Ana tomorrow at 1pm", into: field)
        element(messages, "space").tap()
        wait("calendar.toggle").tap()
        wait("calendar.add").tap()
        _ = wait("calendar.clash")
        shot("new-event-clash")
        // Try instead, then Add: the keyboard writes the event itself, and Undo takes it and the line back out.
        wait("calendar.try.0").tap()
        wait("calendar.addEvent").tap()
        let undo = wait("calendar.undo")
        shot("added-undo")
        undo.tap()
        wait("calendar.close").tap()
        clear(field)
    }
}
