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

    private func label(_ app: XCUIApplication, _ l: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", l)).firstMatch
    }

    private func paste(_ text: String, into field: XCUIElement) {
        UIPasteboard.general.string = text
        field.press(forDuration: 1.0)
        let paste = label(messages, "Paste")
        XCTAssertTrue(paste.waitForExistence(timeout: 4), "no Paste menu")
        paste.tap()
        let allow = messages.alerts.buttons["Allow Paste"]
        if allow.waitForExistence(timeout: 1) { allow.tap() }
        // The paste lands a moment after the tap; clearing the pasteboard sooner can empty it first.
        Thread.sleep(forTimeInterval: 0.6)
        UIPasteboard.general.items = []
    }

    /// A real chat: the first conversation in Messages, with the Pip keyboard up in the message box.
    private func openField() -> XCUIElement {
        messages.terminate()
        messages.launch()
        let chat = messages.cells.firstMatch
        if chat.waitForExistence(timeout: 6) {
            chat.tap()
        } else {
            // A new simulator has no chats: start one to a made-up number.
            let compose = messages.descendants(matching: .any).matching(NSPredicate(format: "label IN {'Compose', 'New Message'}")).firstMatch
            XCTAssertTrue(compose.waitForExistence(timeout: 4), "no conversation and no Compose: \(messages.debugDescription.suffix(3000))")
            compose.tap()
            let to = messages.textFields.firstMatch
            XCTAssertTrue(to.waitForExistence(timeout: 4), "no To field")
            paste("555-0100", into: to)
        }
        // The message box: Messages calls it messageBodyField, with "iMessage" or "Text Message" as its placeholder.
        let body = messages.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == 'messageBodyField' OR placeholderValue IN {'iMessage', 'Text Message', 'Message'} OR label IN {'iMessage', 'Text Message', 'Message'}")).firstMatch
        if body.waitForExistence(timeout: 6) { body.tap() } else { messages.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.945)).tap() }
        XCTAssertTrue(body.exists, "no message box: \(messages.debugDescription.suffix(3000))")
        let intro = label(messages, "Continue")
        if intro.waitForExistence(timeout: 2) { intro.tap() }
        let ours = element(messages, "pip.more")
        for _ in 0..<5 where !ours.waitForExistence(timeout: 1.5) { label(messages, "Next keyboard").tap() }
        XCTAssertTrue(ours.exists, "Pip keyboard not shown")
        return body
    }

    /// Empties the message box with Pip's delete key, pastes the text, then taps Pip's space key so the keyboard reads it as typed.
    private func enter(_ text: String, in field: XCUIElement) {
        let delete = element(messages, "delete")
        for _ in 0..<6 where !((field.value as? String) ?? "").isEmpty && (field.value as? String) != field.placeholderValue {
            delete.press(forDuration: 2.5)
        }
        paste(text, into: field)
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
        element(messages, "chip.explain.more").tap()
        XCTAssertTrue(element(messages, "explain.card").waitForExistence(timeout: 3))
        Thread.sleep(forTimeInterval: 0.4)
        shot("02-btw-card")
        element(messages, "explain.back").tap()

        enter("explain log function", in: field)
        XCTAssertTrue(chip.waitForExistence(timeout: 8), "no explain chip from the server")
        Thread.sleep(forTimeInterval: 0.6)
        shot("03-explain-chip")
        element(messages, "chip.explain.more").tap()
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

        let send = element(messages, "visual.send")
        let done = Date().addingTimeInterval(20)
        while title.label.contains("step"), Date() < done { Thread.sleep(forTimeInterval: 0.2) }
        XCTAssertFalse(title.label.contains("step"), "drawing did not finish: \(title.label)")
        Thread.sleep(forTimeInterval: 0.5)
        shot("06-visual-finished")
        // The upload started when the drawing finished; give it a moment so Send types the link at once.
        Thread.sleep(forTimeInterval: 1.5)

        // One tap: the caption and the short link go into the message, and the image is copied as a fallback.
        send.tap()
        let note = element(messages, "visual.note")
        let linked = NSPredicate(format: "label BEGINSWITH %@", "Link added")
        let linkBy = Date().addingTimeInterval(8)
        while !(note.exists && linked.evaluate(with: note)), Date() < linkBy { Thread.sleep(forTimeInterval: 0.2) }
        XCTAssertTrue(note.exists && linked.evaluate(with: note), "no Link added note: \(note.exists ? note.label : "none")")
        let typed = field.value as? String ?? ""
        XCTAssertTrue(typed.contains("log function, explained: http"), "no caption and link in the field: \(typed)")
        XCTAssertTrue(typed.contains("/d/"), "no link in the field: \(typed)")
        XCTAssertEqual(element(messages, "visual.hint").label, "Image also copied")
        // hasImages does not show the paste prompt; reading the image would, so the test does not read it.
        XCTAssertTrue(UIPasteboard.general.hasImages, "no image on the pasteboard")
        shot("07-send-link-inserted")

        // Send as image waits in the small menu.
        element(messages, "visual.more").tap()
        let copy = element(messages, "visual.send.image")
        XCTAssertTrue(copy.waitForExistence(timeout: 3))
        shot("08-send-menu")
        copy.tap()
        let copied = NSPredicate(format: "label BEGINSWITH %@", "Copied")
        let until = Date().addingTimeInterval(8)
        while !(note.exists && copied.evaluate(with: note)), Date() < until { Thread.sleep(forTimeInterval: 0.2) }
        XCTAssertTrue(note.exists && copied.evaluate(with: note), "no Copied note: \(note.exists ? note.label : "none")")
        shot("08b-send-as-image-copied")
        XCTAssertTrue(UIPasteboard.general.hasImages, "no image on the pasteboard")
    }

    /// The three drawing scenes in a Messages chat: log (mid-drawing and finished), a bar chart and a pie chart.
    /// It writes anim-start.txt (epoch seconds) when the log drawing starts, to cut a screen recording.
    func test7DrawingScenes() {
        let engine = "pip"
        let field = openField()
        let title = element(messages, "explain.title")
        func waitDone(_ what: String) {
            let started = Date().addingTimeInterval(8)
            while !title.label.contains("step"), Date() < started { Thread.sleep(forTimeInterval: 0.1) }
            let done = Date().addingTimeInterval(25)
            while title.label.contains("step"), Date() < done { Thread.sleep(forTimeInterval: 0.2) }
            XCTAssertFalse(title.label.contains("step"), "\(what) did not finish: \(title.label)")
            Thread.sleep(forTimeInterval: 0.6)
        }

        enter("explain log function", in: field)
        let more = element(messages, "chip.explain.more")
        XCTAssertTrue(more.waitForExistence(timeout: 8), "no explain chip")
        more.tap()
        let visual = element(messages, "explain.visual")
        XCTAssertTrue(visual.waitForExistence(timeout: 3))
        if let dir = env["SHOT_DIR"] { try? String(Date().timeIntervalSince1970).write(toFile: dir + "/anim-start.txt", atomically: true, encoding: .utf8) }
        visual.tap()
        let mid = NSPredicate(format: "label CONTAINS %@", "step 2 of")
        let deadline = Date().addingTimeInterval(15)
        while !mid.evaluate(with: title), Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        Thread.sleep(forTimeInterval: 0.5)
        shot("\(engine)-1-log-mid")
        waitDone("log")
        shot("\(engine)-2-log-finished")
        element(messages, "explain.close").tap()

        for (name, text) in [("3-bar", "bar chart: rent 1200, food 400, fun 200"), ("4-pie", "pie chart of my week: work 40 sleep 56 other 72")] {
            enter(text, in: field)
            let chip = element(messages, "chip.explain")
            XCTAssertTrue(chip.waitForExistence(timeout: 4), "no chart chip for \(text)")
            chip.tap()
            waitDone(name)
            shot("\(engine)-\(name)")
            element(messages, "explain.close").tap()
        }
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
