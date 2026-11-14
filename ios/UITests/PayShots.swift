import XCTest

/// Pip Pay, phone-signed, on NEAR testnet against `npm run fake` (a fake chain; no network; the server checks the real signature). Run SmartChipShots/test1Setup first to pair
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

    /// Home → Pip Pay → Set up (C-3): the phone makes its key and registers its implicit account. Then the mainnet warning.
    func test1PaySetup() {
        let app = XCUIApplication()
        app.launch()
        let row = element(app, "home.keyboardPay")
        for _ in 0..<6 where !(row.exists && row.isHittable) { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(row.waitForExistence(timeout: 10), String(app.debugDescription.suffix(3000)))
        row.tap()
        let setUp = element(app, "kbpay.turnOn")
        XCTAssertTrue(setUp.waitForExistence(timeout: 6))
        if setUp.label == "Set up Pip Pay" { setUp.tap() }
        XCTAssertTrue(label(app, "Pip Pay is on \u{2713}").waitForExistence(timeout: 15), String(app.debugDescription.suffix(3000)))
        XCTAssertTrue(element(app, "pay.balance").waitForExistence(timeout: 6), String(app.debugDescription.suffix(3000)))
        shot("near-setup")
        let mainnet = app.segmentedControls.buttons["Mainnet"]
        XCTAssertTrue(mainnet.waitForExistence(timeout: 6), String(app.debugDescription.suffix(3000)))
        mainnet.tap()
        XCTAssertTrue(element(app, "pay.mainnetWarning").waitForExistence(timeout: 8), String(app.debugDescription.suffix(3000)))
        XCTAssertTrue(element(app, "pay.balance").waitForExistence(timeout: 8))
        shot("near-mainnet-warning")
        app.segmentedControls.buttons["Testnet"].tap()
        XCTAssertTrue(element(app, "pay.mainnetWarning").waitForNonExistence(timeout: 8))
    }

    /// First send to ana: a new recipient, so the keyboard hands it to the app (A-style card), then Face ID.
    func test2FirstSendOpensTheApp() {
        let field = openField()
        enter(env["PAY_TEXT"] ?? "send 5 USDC to \(env["PAY_TO"] ?? "ana").near", in: field)
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

    /// Boss man's P0: in Messages, "Approve with PIN" opens Pip's number pad inside the keyboard, the PIN signs, and the
    /// payment is sent without the app. Sets the PIN in the app first when it is not on (Face ID: post a match while this runs).
    func test5ApproveWithPINInTheKeyboard() {
        let pin = env["PAY_PIN"] ?? "482915"
        let app = XCUIApplication()
        app.launch()
        let row = element(app, "home.keyboardPay")
        for _ in 0..<6 where !(row.exists && row.isHittable) { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(row.waitForExistence(timeout: 10), String(app.debugDescription.suffix(3000)))
        row.tap()
        let state = element(app, "pay.pinState")
        XCTAssertTrue(state.waitForExistence(timeout: 10), String(app.debugDescription.suffix(3000)))
        if state.label != "On" {
            let field = element(app, "pinsetup.field")
            if !field.waitForExistence(timeout: 3) { element(app, "pay.pinAction").tap() }
            XCTAssertTrue(field.waitForExistence(timeout: 6), String(app.debugDescription.suffix(3000)))
            field.typeText(pin)
            Thread.sleep(forTimeInterval: 0.5)
            field.typeText(pin)
            XCTAssertTrue(state.waitForExistence(timeout: 20))
            let on = NSPredicate(format: "label == 'On'")
            expectation(for: on, evaluatedWith: state)
            waitForExpectations(timeout: 20)
        }
        let field = openField()
        enter(env["PAY_TEXT"] ?? "send 5 USDC to ana.near", in: field)
        let chip = element(messages, "chip.pay")
        if !chip.waitForExistence(timeout: 6) {
            Thread.sleep(forTimeInterval: 5.5)
            element(messages, "delete").tap()
            element(messages, "space").tap()
        }
        XCTAssertTrue(chip.waitForExistence(timeout: 6), String(messages.debugDescription.suffix(3000)))
        chip.tap()
        let approve = element(messages, "paycard.approve")
        XCTAssertTrue(approve.waitForExistence(timeout: 10), String(messages.debugDescription.suffix(4000)))
        // A first payment to this address: tap how it ends, inside the keyboard.
        let ends = messages.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'paycard.end.'"))
        if ends.firstMatch.waitForExistence(timeout: 1) {
            let to = env["PAY_TO_FULL"] ?? "ana.testnet"
            let name = [".testnet", ".near"].first { to.hasSuffix($0) }.map { String(to.dropLast($0.count)) } ?? to
            let right = (0..<ends.count).map { ends.element(boundBy: $0) }.first { name.hasSuffix(String($0.identifier.dropFirst("paycard.end.".count))) }
            XCTAssertNotNil(right)
            right?.tap()
        }
        approve.tap()
        XCTAssertTrue(element(messages, "pin.pad").waitForExistence(timeout: 5), String(messages.debugDescription.suffix(4000)))
        XCTAssertTrue(element(messages, "pin.dots").exists)
        XCTAssertFalse(element(messages, "paycard.approveInApp").exists, "no app hop on the pad")
        shot("pin-pad-keyboard")
        for d in pin { element(messages, "pin.\(d)").tap() }
        let insert = element(messages, "paycard.insert")
        XCTAssertTrue(insert.waitForExistence(timeout: 25), String(messages.debugDescription.suffix(4000)))
        XCTAssertEqual(messages.state, .runningForeground, "the app never opened")
        shot("pin-pad-sent")
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
