import XCTest

/// Pip Pay on NEAR testnet against `npm run fake` (a fake chain; no network). Run SmartChipShots/test1Setup first to pair
/// and turn the keyboard on. Face ID: enroll the simulator and post a match while this runs (see docs in the report):
/// `xcrun simctl spawn <sim> notifyutil -p com.apple.BiometricKit_Sim.pearl.match`. Writes to TEST_RUNNER_SHOT_DIR.
final class PayShots: XCTestCase {
    private let env = ProcessInfo.processInfo.environment
    private let messages = XCUIApplication(bundleIdentifier: "com.apple.MobileSMS")
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    override func setUp() { continueAfterFailure = false }

    private func shot(_ name: String) {
        Thread.sleep(forTimeInterval: 0.8)
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
        Thread.sleep(forTimeInterval: 0.6)
        UIPasteboard.general.items = []
    }

    /// The first chat in Messages with the Pip keyboard up in the message box.
    private func openField() -> XCUIElement {
        messages.terminate()
        messages.launch()
        // A New Message sheet left open by an earlier run covers the chat list.
        let cancel = messages.buttons.matching(NSPredicate(format: "label IN {'Cancel', 'Close'}")).firstMatch
        if cancel.waitForExistence(timeout: 2) { cancel.tap() }
        let chat = messages.cells.firstMatch
        if chat.waitForExistence(timeout: 6) {
            chat.tap()
        } else {
            let compose = messages.descendants(matching: .any).matching(NSPredicate(format: "label IN {'Compose', 'New Message'}")).firstMatch
            XCTAssertTrue(compose.waitForExistence(timeout: 4))
            compose.tap()
            let to = messages.textFields.firstMatch
            XCTAssertTrue(to.waitForExistence(timeout: 4))
            paste("555-0100", into: to)
        }
        let body = messages.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == 'messageBodyField' OR placeholderValue IN {'iMessage', 'Text Message', 'Message'} OR label IN {'iMessage', 'Text Message', 'Message'}")).firstMatch
        if body.waitForExistence(timeout: 6) { body.tap() } else { messages.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.945)).tap() }
        let intro = label(messages, "Continue")
        if intro.waitForExistence(timeout: 2) { intro.tap() }
        let ours = element(messages, "pip.more")
        for _ in 0..<5 where !ours.waitForExistence(timeout: 1.5) { label(messages, "Next keyboard").tap() }
        XCTAssertTrue(ours.exists, "Pip keyboard not shown")
        return body
    }

    private func enter(_ text: String, in field: XCUIElement) {
        let delete = element(messages, "delete")
        for _ in 0..<6 where !((field.value as? String) ?? "").isEmpty && (field.value as? String) != field.placeholderValue {
            delete.press(forDuration: 2.5)
        }
        paste(text, into: field)
        Thread.sleep(forTimeInterval: 0.3)
        element(messages, "space").tap()
    }

    /// Home → "Pay from the keyboard" → Turn on (C-3).
    func test1KeyboardPaySetup() {
        let app = XCUIApplication()
        app.launch()
        let row = element(app, "home.keyboardPay")
        for _ in 0..<6 where !(row.exists && row.isHittable) { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(row.waitForExistence(timeout: 10), String(app.debugDescription.suffix(3000)))
        row.tap()
        XCTAssertTrue(element(app, "kbpay.turnOn").waitForExistence(timeout: 6))
        shot("near-setup")
        element(app, "kbpay.turnOn").tap()
        XCTAssertTrue(label(app, "Keyboard pay is on \u{2713}").waitForExistence(timeout: 15), String(app.debugDescription.suffix(3000)))
    }

    /// First send to ana: a new recipient, so the keyboard hands it to the app (A-style card), then Face ID.
    func test2FirstSendOpensTheApp() {
        let field = openField()
        enter("send 5 USDC to \(env["PAY_TO"] ?? "ana").near", in: field)
        let chip = element(messages, "chip.pay")
        XCTAssertTrue(chip.waitForExistence(timeout: 6), String(messages.debugDescription.suffix(3000)))
        shot("near-chip")
        chip.tap()
        let open = springboard.buttons["Open"]
        if open.waitForExistence(timeout: 4) { open.tap() }
        let app = XCUIApplication()
        if !element(app, "pay.approve").waitForExistence(timeout: 8) {
            // The keyboard could not open the app: open it by hand, as the bar says.
            app.activate()
        }
        XCTAssertTrue(element(app, "pay.approve").waitForExistence(timeout: 10), String(app.debugDescription.suffix(3000)))
        Thread.sleep(forTimeInterval: 1.5)
        shot("near-approve-app")
        element(app, "pay.approve").tap()
        XCTAssertTrue(element(app, "pay.sent").waitForExistence(timeout: 20), String(app.debugDescription.suffix(3000)))
        shot("near-sent-app")
        element(app, "pay.done").tap()
    }

    /// Second send to ana: paid before and within the limit, so the card and Face ID stay in the keyboard (C-1, C-2).
    func test3SecondSendStaysInTheKeyboard() {
        let field = openField()
        // The app's send from test 2 waits on the bar as a receipt line with Insert (A-3).
        let paid = element(messages, "chip.paid.insert")
        if paid.waitForExistence(timeout: 4) {
            shot("near-sent-line")
            paid.tap()
            Thread.sleep(forTimeInterval: 0.6)
        }
        enter("send 5 USDC to ana.near", in: field)
        let chip = element(messages, "chip.pay")
        if !chip.waitForExistence(timeout: 6) {
            // A paste reads as typing past the last chip, which quiets chips for 5 s. One more key after that.
            Thread.sleep(forTimeInterval: 5.5)
            element(messages, "delete").tap()
            element(messages, "space").tap()
        }
        XCTAssertTrue(chip.waitForExistence(timeout: 6), String(messages.debugDescription.suffix(3000)))
        chip.tap()
        let approve = element(messages, "paycard.approve")
        XCTAssertTrue(approve.waitForExistence(timeout: 8), String(messages.debugDescription.suffix(3000)))
        shot("near-approve")
        approve.tap()
        let insert = element(messages, "paycard.insert")
        XCTAssertTrue(insert.waitForExistence(timeout: 20), String(messages.debugDescription.suffix(4000)))
        shot("near-sent")
        insert.tap()
        Thread.sleep(forTimeInterval: 1)
        shot("near-inserted")
    }

    func test4PrivateAIProof() {
        let app = XCUIApplication()
        app.launch()
        let row = element(app, "home.privateAI")
        for _ in 0..<6 where !(row.exists && row.isHittable) { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(element(app, "proof.notChecked").waitForExistence(timeout: 10), String(app.debugDescription.suffix(3000)))
        shot("near-proof")
    }
}
