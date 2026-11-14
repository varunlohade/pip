import XCTest

/// Cross-chain pay in the keyboard against `npm run fake` (a fake 1Click and NEAR; no network). Run SmartChipShots/test1Setup
/// first to pair and turn the keyboard on, and PayShots/test2 to set the Pip PIN (PAY_PIN). Every approve goes through the
/// in-keyboard PIN pad. FAKE_URL names the fake server; shots go to SHOT_DIR.
final class XchainShots: XCTestCase {
    private let env = ProcessInfo.processInfo.environment
    private let messages = XCUIApplication(bundleIdentifier: "com.apple.MobileSMS")
    private let text = "send 5 USDC to 0xd8da6bf26964af9d7eed9e10c19b4ae4ff1b9da3 on base"
    private var pin: String { env["PAY_PIN"] ?? "482915" }

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

    private func post(_ path: String, _ json: String) {
        var r = URLRequest(url: URL(string: (env["FAKE_URL"] ?? "http://127.0.0.1:8799") + path)!)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = Data(json.utf8)
        let done = expectation(description: path)
        URLSession.shared.dataTask(with: r) { _, _, _ in done.fulfill() }.resume()
        wait(for: [done], timeout: 5)
    }

    /// Taps Approve with PIN and types the PIN on the in-keyboard pad.
    private func approveWithPIN() {
        XCTAssertTrue(element(messages, "paycard.approve").label.contains("Approve with PIN"), String(messages.debugDescription.suffix(4000)))
        element(messages, "paycard.approve").tap()
        XCTAssertTrue(element(messages, "pin.pad").waitForExistence(timeout: 8), String(messages.debugDescription.suffix(4000)))
        for d in pin { element(messages, "pin.\(d)").tap() }
    }

    /// Moves the fake server's clock, so the next approve re-quotes.
    private func tick(_ ms: Int) { post("/_tick", #"{"ms":\#(ms)}"#) }

    private func paste(_ s: String, into field: XCUIElement) {
        UIPasteboard.general.string = s
        field.press(forDuration: 1.0)
        let paste = label(messages, "Paste")
        XCTAssertTrue(paste.waitForExistence(timeout: 4), "no Paste menu")
        paste.tap()
        let allow = messages.alerts.buttons["Allow Paste"]
        if allow.waitForExistence(timeout: 1) { allow.tap() }
        Thread.sleep(forTimeInterval: 0.6)
        UIPasteboard.general.items = []
    }

    private func openField() -> XCUIElement {
        messages.terminate()
        messages.launch()
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

    /// Pastes the ask and waits for `chipID`; a paste reads as typing past a chip, so it nudges once after the quiet time.
    private func ask(_ chipID: String, in field: XCUIElement, text: String? = nil) -> XCUIElement {
        let delete = element(messages, "delete")
        for _ in 0..<6 where !((field.value as? String) ?? "").isEmpty && (field.value as? String) != field.placeholderValue {
            delete.press(forDuration: 2.5)
        }
        paste(text ?? self.text, into: field)
        element(messages, "space").tap()
        let chip = element(messages, chipID)
        if !chip.waitForExistence(timeout: 6) {
            Thread.sleep(forTimeInterval: 5.5)
            element(messages, "delete").tap()
            element(messages, "space").tap()
        }
        XCTAssertTrue(chip.waitForExistence(timeout: 8), String(messages.debugDescription.suffix(3000)))
        return chip
    }

    private func pipPay(network: String) {
        let app = XCUIApplication()
        app.launch()
        let setUp = element(app, "kbpay.turnOn")
        // The app can reopen on the Pip Pay page it was left on.
        if !setUp.waitForExistence(timeout: 2) {
            let row = element(app, "home.keyboardPay")
            for _ in 0..<6 where !(row.exists && row.isHittable) { app.swipeUp(velocity: .slow) }
            XCTAssertTrue(row.waitForExistence(timeout: 10), String(app.debugDescription.suffix(3000)))
            row.tap()
        }
        XCTAssertTrue(setUp.waitForExistence(timeout: 6))
        if setUp.label == "Set up Pip Pay" { setUp.tap() }
        XCTAssertTrue(element(app, "pay.balance").waitForExistence(timeout: 15), String(app.debugDescription.suffix(3000)))
        let seg = app.segmentedControls.buttons[network]
        XCTAssertTrue(seg.waitForExistence(timeout: 6))
        seg.tap()
        if network == "Mainnet" { XCTAssertTrue(element(app, "pay.mainnetWarning").waitForExistence(timeout: 8)) }
        XCTAssertTrue(element(app, "pay.balance").waitForExistence(timeout: 8))
        Thread.sleep(forTimeInterval: 1)
    }

    func test1Testnet() {
        pipPay(network: "Testnet")
        let field = openField()
        _ = ask("chip.pay.info", in: field)
        shot("xchain-chip-testnet")
    }

    func test2MainnetFirstTimeRequoteStatus() {
        pipPay(network: "Mainnet")
        let field = openField()
        let chip = ask("chip.pay", in: field)
        shot("xchain-chip")
        chip.tap()
        let warn = element(messages, "paycard.firsttime")
        XCTAssertTrue(warn.waitForExistence(timeout: 10), String(messages.debugDescription.suffix(4000)))
        shot("xchain-first-time")
        element(messages, "paycard.end.9da3").tap()
        // Over a minute later: the server re-quotes before it builds.
        tick(61_000)
        approveWithPIN()
        XCTAssertTrue(element(messages, "xcard.requoted").waitForExistence(timeout: 15), String(messages.debugDescription.suffix(4000)))
        shot("xchain-requote")
        approveWithPIN()
        XCTAssertTrue(element(messages, "xcard.status").waitForExistence(timeout: 15), String(messages.debugDescription.suffix(4000)))
        XCTAssertTrue(element(messages, "xcard.explorer").waitForExistence(timeout: 20), String(messages.debugDescription.suffix(4000)))
        shot("xchain-status")
        element(messages, "paycard.close").tap()
    }

    /// Paid before: the card shows without the address check.
    func test3MainnetKnownAddressCard() {
        let field = openField()
        let chip = ask("chip.pay", in: field)
        chip.tap()
        XCTAssertTrue(element(messages, "paycard.approve").waitForExistence(timeout: 10), String(messages.debugDescription.suffix(4000)))
        XCTAssertFalse(element(messages, "paycard.firsttime").exists)
        XCTAssertTrue(element(messages, "paycard.approve").label.contains("Approve with PIN"), String(messages.debugDescription.suffix(4000)))
        shot("xchain-card")
        element(messages, "paycard.reject").tap()
    }

    /// Testnet: "swap 1 near to usdc" shows a live preview card (real prices, Approve off).
    func test4SwapPreview() {
        pipPay(network: "Testnet")
        post("/_next", #"{"route":{"label":"swap","confidence":0.9}}"#)
        let field = openField()
        let chip = ask("chip.pay", in: field, text: "swap 1 near to usdc")
        chip.tap()
        XCTAssertTrue(element(messages, "swapcard.preview").waitForExistence(timeout: 10), String(messages.debugDescription.suffix(4000)))
        shot("swap-preview")
        element(messages, "paycard.reject").tap()
    }
}
