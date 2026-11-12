import XCTest

/// Explain in the real Pip keyboard, in the Messages search field, against `npm run fake` (no model call; the fake answers
/// with the log-function fixtures). Run SmartChipShots/test1Setup first to pair and turn the keyboard on, then this, with
/// TEST_RUNNER_SHOT_DIR set. The last test opens Pip to show "Your drawings".
final class ExplainShots: XCTestCase {
    private let env = ProcessInfo.processInfo.environment
    private let messages = XCUIApplication(bundleIdentifier: "com.apple.MobileSMS")

    override func setUp() { continueAfterFailure = false }

    private func shot(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let dir = env["SHOT_DIR"] { try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png")) }
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@", id)).firstMatch
    }

    private func openField() -> XCUIElement {
        messages.terminate()
        messages.launch()
        let search = messages.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 8))
        search.tap()
        let intro = messages.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Continue")).firstMatch
        if intro.waitForExistence(timeout: 2) { intro.tap() }
        let ours = element(messages, "pip.more")
        for _ in 0..<5 where !ours.waitForExistence(timeout: 1.5) {
            messages.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Next keyboard")).firstMatch.tap()
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
        let paste = messages.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Paste")).firstMatch
        XCTAssertTrue(paste.waitForExistence(timeout: 4), "no Paste menu")
        paste.tap()
        let allow = messages.alerts.buttons["Allow Paste"]
        if allow.waitForExistence(timeout: 1) { allow.tap() }
        UIPasteboard.general.items = []
        Thread.sleep(forTimeInterval: 0.3)
        element(messages, "space").tap()
    }

    func test2Explain() {
        let field = openField()

        enter("what does btw mean", in: field)
        let chip = element(messages, "chip.explain")
        XCTAssertTrue(chip.waitForExistence(timeout: 4), "no btw chip")
        Thread.sleep(forTimeInterval: 0.6)
        shot("01-btw-chip")
        chip.tap()
        XCTAssertTrue(element(messages, "explain.card").waitForExistence(timeout: 3))
        Thread.sleep(forTimeInterval: 0.4)
        shot("02-btw-card")
        element(messages, "explain.back").tap()

        enter("explain log function", in: field)
        XCTAssertTrue(chip.waitForExistence(timeout: 8), "no explain chip from the server")
        Thread.sleep(forTimeInterval: 0.6)
        shot("03-explain-chip")
        chip.tap()
        let visual = element(messages, "explain.visual")
        XCTAssertTrue(visual.waitForExistence(timeout: 3))
        Thread.sleep(forTimeInterval: 0.4)
        shot("04-explain-card")
        visual.tap()

        // Mid-drawing: the title says which step is drawing.
        let title = element(messages, "explain.title")
        let mid = NSPredicate(format: "label CONTAINS %@", "step 2 of")
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        let deadline = Date().addingTimeInterval(15)
        while !mid.evaluate(with: title), Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        XCTAssertTrue(mid.evaluate(with: title), "never reached step 2: \(title.label)")
        Thread.sleep(forTimeInterval: 0.5)
        shot("05-visual-mid-drawing")

        let copy = element(messages, "visual.send.image")
        let done = Date().addingTimeInterval(20)
        while title.label.contains("step"), Date() < done { Thread.sleep(forTimeInterval: 0.2) }
        XCTAssertFalse(title.label.contains("step"), "drawing did not finish: \(title.label)")
        Thread.sleep(forTimeInterval: 0.5)
        shot("06-visual-finished")

        copy.tap()
        let note = element(messages, "visual.note")
        let copied = NSPredicate(format: "label BEGINSWITH %@", "Copied")
        let until = Date().addingTimeInterval(8)
        while !(note.exists && copied.evaluate(with: note)), Date() < until { Thread.sleep(forTimeInterval: 0.2) }
        XCTAssertTrue(note.exists && copied.evaluate(with: note), "no Copied note: \(note.exists ? note.label : "none")")
        shot("07-export-copied")
        // hasImages does not show the paste prompt; reading the image would, so the test does not read it.
        XCTAssertTrue(UIPasteboard.general.hasImages, "no image on the pasteboard")

        element(messages, "visual.send.link").tap()
        let linked = NSPredicate(format: "label BEGINSWITH %@", "Link added")
        let linkBy = Date().addingTimeInterval(8)
        while !(note.exists && linked.evaluate(with: note)), Date() < linkBy { Thread.sleep(forTimeInterval: 0.2) }
        XCTAssertTrue(note.exists && linked.evaluate(with: note), "no Link added note: \(note.exists ? note.label : "none")")
        XCTAssertTrue((field.value as? String ?? "").contains("/d/"), "no link in the field: \(field.value ?? "")")
        shot("08-send-link")
    }

    /// Charts read on the phone: no server call, drawn step by step, then finished.
    func test4Charts() {
        let field = openField()
        let chip = element(messages, "chip.explain")
        let title = element(messages, "explain.title")
        for (name, text) in [("10-bar-chart", "bar chart: rent 1200, food 400, fun 200"), ("11-graph-x-squared", "graph y = x^2"),
                             ("12-pie-chart", "pie chart of my week: work 40 sleep 56 other 72"), ("13-line-chart", "line chart 3, 5, 9, 4"),
                             ("14-graph-sin", "plot sin x")] {
            enter(text, in: field)
            XCTAssertTrue(chip.waitForExistence(timeout: 4), "no chart chip for \(text)")
            if name == "10-bar-chart" { Thread.sleep(forTimeInterval: 0.5); shot("10-bar-chart-chip") }
            chip.tap()
            XCTAssertTrue(title.waitForExistence(timeout: 4))
            let started = Date().addingTimeInterval(8)
            while !title.label.contains("step"), Date() < started { Thread.sleep(forTimeInterval: 0.1) }
            let done = Date().addingTimeInterval(20)
            while title.label.contains("step"), Date() < done { Thread.sleep(forTimeInterval: 0.2) }
            XCTAssertFalse(title.label.contains("step"), "\(text) did not finish: \(title.label)")
            Thread.sleep(forTimeInterval: 0.5)
            shot(name)
            element(messages, "explain.close").tap()
        }
    }

    func test3Drawings() {
        let app = XCUIApplication()
        app.launch()
        let drawings = element(app, "home.drawings")
        if !drawings.waitForExistence(timeout: 8) { app.swipeUp() }
        XCTAssertTrue(drawings.waitForExistence(timeout: 4), "no Your drawings on Home")
        drawings.swipeUp()
        Thread.sleep(forTimeInterval: 0.6)
        shot("09-home-your-drawings")
    }
}
