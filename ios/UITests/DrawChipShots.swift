import XCTest

/// TestFlight 0.4 (5) fixes, tapped through in Messages and Notes against `npm run fake`:
/// "explain compued interest" shows the answer and Draw it in the bar; Draw it opens the drawing at once;
/// "usdt" typed on the keys stays "usdt"; a Fix leaves no "Fixed" line. Run SmartChipShots/test1Setup first.
/// Writes fix-draw-chip.png to TEST_RUNNER_SHOT_DIR.
final class DrawChipShots: XCTestCase {
    private let env = ProcessInfo.processInfo.environment
    private let messages = XCUIApplication(bundleIdentifier: "com.apple.MobileSMS")
    private let notes = XCUIApplication(bundleIdentifier: "com.apple.mobilenotes")

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

    /// The fake server's next explain answer, so the chip reads like the real one.
    private func nextExplain() {
        var r = URLRequest(url: URL(string: (env["FAKE_URL"] ?? "http://127.0.0.1:8799") + "/_next")!)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = Data(#"{"explain":{"short":"Interest on your interest","body":["You earn on what you saved, then on what it earned."],"visual_ok":true}}"#.utf8)
        let done = expectation(description: "next")
        URLSession.shared.dataTask(with: r) { _, _, _ in done.fulfill() }.resume()
        wait(for: [done], timeout: 5)
    }

    private func pipUp(_ app: XCUIApplication) {
        let ours = element(app, "pip.more")
        for _ in 0..<5 where !ours.waitForExistence(timeout: 1.5) { label(app, "Next keyboard").tap() }
        XCTAssertTrue(ours.exists, "Pip keyboard not shown")
    }

    /// Taps Pip's own letter keys, so autocorrect runs as it does for a person.
    private func typeKeys(_ app: XCUIApplication, _ text: String) {
        for ch in text {
            if ch == " " { element(app, "space").tap(); continue }
            let key = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'k.' AND label ==[c] %@", String(ch))).firstMatch
            XCTAssertTrue(key.waitForExistence(timeout: 2), "no key \(ch)")
            key.tap()
        }
    }

    /// Pastes, then taps Pip's space key so the keyboard reads it as typed. Pasted text skips autocorrect, so a typo stays for Fix.
    private func paste(_ app: XCUIApplication, _ text: String, into field: XCUIElement) {
        UIPasteboard.general.string = text
        field.press(forDuration: 1.0)
        let paste = label(app, "Paste")
        XCTAssertTrue(paste.waitForExistence(timeout: 4), "no Paste menu")
        paste.tap()
        let allow = app.alerts.buttons["Allow Paste"]
        if allow.waitForExistence(timeout: 1) { allow.tap() }
        Thread.sleep(forTimeInterval: 0.6)
        UIPasteboard.general.items = []
        element(app, "space").tap()
    }

    private func clear(_ app: XCUIApplication, _ field: XCUIElement) {
        let delete = element(app, "delete")
        for _ in 0..<6 where !((field.value as? String) ?? "").isEmpty && (field.value as? String) != field.placeholderValue {
            delete.press(forDuration: 2.5)
        }
    }

    private func post(_ path: String, _ json: String = "{}") {
        var r = URLRequest(url: URL(string: (env["FAKE_URL"] ?? "http://127.0.0.1:8799") + path)!)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = Data(json.utf8)
        let done = expectation(description: path)
        URLSession.shared.dataTask(with: r) { _, _, _ in done.fulfill() }.resume()
        wait(for: [done], timeout: 5)
    }

    /// How many requests the fake server has seen.
    private func requestCount() -> Int {
        let done = expectation(description: "log")
        var n = -1
        URLSession.shared.dataTask(with: URL(string: (env["FAKE_URL"] ?? "http://127.0.0.1:8799") + "/_log")!) { d, _, _ in
            if let d, let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let r = j["requests"] as? [Any] { n = r.count }
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 5)
        return n
    }

    private func openChat() -> XCUIElement {
        messages.terminate()
        messages.launch()
        let chat = messages.cells.firstMatch
        XCTAssertTrue(chat.waitForExistence(timeout: 6), "run ExplainShots once to make a chat")
        chat.tap()
        let body = messages.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == 'messageBodyField' OR placeholderValue IN {'iMessage', 'Text Message', 'Message'}")).firstMatch
        XCTAssertTrue(body.waitForExistence(timeout: 6))
        body.tap()
        pipUp(messages)
        return body
    }

    /// The five 0.5 checks in a Messages chat: explain + Draw it, calendar, pay, plain chat, and a password.
    func testFiveChecksInMessages() {
        post("/_reset")
        let body = openChat()

        // 1. "how do mortgages work": the answer and Draw it; Draw it opens the drawing, not the card.
        clear(messages, body)
        nextExplain()
        paste(messages, "how do mortgages work", into: body)
        let draw = element(messages, "chip.draw")
        XCTAssertTrue(draw.waitForExistence(timeout: 8), "1: no Draw it")
        XCTAssertTrue(element(messages, "chip.explain").waitForExistence(timeout: 8), "1: no explain chip")
        Thread.sleep(forTimeInterval: 0.6)
        shot("fix-draw-chip")
        draw.tap()
        XCTAssertTrue(element(messages, "explain.close").waitForExistence(timeout: 3), "1: no drawing panel")
        XCTAssertFalse(element(messages, "explain.card").exists, "1: the text card opened")
        shot("check1-draw-panel")
        element(messages, "explain.close").tap()

        // 2. A calendar chip.
        clear(messages, body)
        paste(messages, "dinner with ana friday 7pm", into: body)
        let cal = messages.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'chip.smart.event' OR identifier == 'chip.allow.Calendar'")).firstMatch
        let calShown = cal.waitForExistence(timeout: 6)
        shot("check2-calendar")
        XCTAssertTrue(calShown, "2: no calendar chip")

        // 3. A pay chip.
        clear(messages, body)
        paste(messages, "send 0.01 NEAR to x.testnet", into: body)
        XCTAssertTrue(element(messages, "chip.pay").waitForExistence(timeout: 6), "3: no pay chip")
        shot("check3-pay")

        // 4. Plain chat: nothing about the typing.
        clear(messages, body)
        paste(messages, "hey how are you", into: body)
        Thread.sleep(forTimeInterval: 2.5)
        for id in ["chip.draw", "chip.explain", "chip.pay", "chip.secret"] { XCTAssertFalse(element(messages, id).exists, "4: \(id) showed") }
        shot("check4-nothing")

        // 5. A password: the quiet AI-off line, and no request at all.
        clear(messages, body)
        Thread.sleep(forTimeInterval: 1.5)
        let before = requestCount()
        paste(messages, "my login is Tr0ub4dor&3x", into: body)
        let secretShown = element(messages, "chip.secret").waitForExistence(timeout: 3)
        shot("check5-secret-before")
        XCTAssertTrue(secretShown, "5: no AI-off line: \(body.value ?? "")")
        Thread.sleep(forTimeInterval: 3)
        XCTAssertEqual(requestCount(), before, "5: a request went out")
        XCTAssertEqual(body.value as? String, "my login is Tr0ub4dor&3x ", "5: the typed text changed")
        shot("check5-secret")
        clear(messages, body)
    }

    func testCheck5Only() {
        post("/_reset")
        let body = openChat()
        clear(messages, body)
        Thread.sleep(forTimeInterval: 1.5)
        let before = requestCount()
        paste(messages, "my login is Tr0ub4dor&3x", into: body)
        let secretShown = element(messages, "chip.secret").waitForExistence(timeout: 3)
        shot("check5-secret-before")
        XCTAssertTrue(secretShown, "5: no AI-off line: \(body.value ?? "")")
        Thread.sleep(forTimeInterval: 3)
        XCTAssertEqual(requestCount(), before, "5: a request went out")
        clear(messages, body)
    }

    /// "usdt" typed on the keys stays "usdt"; a Fix leaves no "Fixed" line.
    func testUSDTAndQuietFixInMessages() {
        post("/_reset")
        let body = openChat()
        clear(messages, body)
        typeKeys(messages, "send usdt now ")
        XCTAssertEqual(body.value as? String, "Send usdt now ", "autocorrect changed a token symbol")
        shot("fix-usdt-kept")
        clear(messages, body)
        paste(messages, "can u send teh bill", into: body)
        let fix = element(messages, "chip.fix")
        let fixShown = fix.waitForExistence(timeout: 6)
        shot("fix-chip-before")
        XCTAssertTrue(fixShown, "no Fix chip")
        fix.tap()
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertFalse(messages.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Fixed'")).firstMatch.exists, "a Fixed line showed")
        XCTAssertTrue((body.value as? String ?? "").contains("the bill"), "not fixed: \(body.value ?? "")")
        shot("fix-no-toast")
        clear(messages, body)
    }

    func testNotesFixHasNoConfirmation() {
        notes.terminate()
        notes.launch()
        for l in ["Continue", "Not Now"] where label(notes, l).waitForExistence(timeout: 2) { label(notes, l).tap() }
        let new = notes.descendants(matching: .any).matching(NSPredicate(format: "label IN {'New note', 'New Note', 'Compose'}")).firstMatch
        XCTAssertTrue(new.waitForExistence(timeout: 6), "no new note button: \(notes.debugDescription.suffix(2000))")
        new.tap()
        let text = notes.textViews.firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        text.tap()
        pipUp(notes)

        // 4. Fix: the typo goes, and no "Fixed" line or Undo chip shows.
        paste(notes, "can u send teh bill", into: text)
        let fix = element(notes, "chip.fix")
        XCTAssertTrue(fix.waitForExistence(timeout: 6), "no Fix chip")
        fix.tap()
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertFalse(notes.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Fixed'")).firstMatch.exists, "a Fixed line showed")
        XCTAssertFalse(element(notes, "chip.undo").exists, "an Undo chip showed")
        XCTAssertTrue((text.value as? String ?? "").contains("the bill"), "not fixed: \(text.value ?? "")")
        shot("fix-no-toast-notes")

        // 5. Explain works in Notes too.
        typeKeys(notes, " explian photosynthesis")
        XCTAssertTrue(element(notes, "chip.draw").waitForExistence(timeout: 8), "no Draw it in Notes")
        shot("fix-draw-chip-notes")
    }
}
