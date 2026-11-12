import XCTest

/// Sums on the bar in the real Pip keyboard, in the Messages search field. Run SmartChipShots/test1Setup first (pairs with
/// `npm run fake` and turns the keyboard on). TEST_RUNNER_SHOT_DIR saves the chip screenshots.
final class CalcChipTest: XCTestCase {
    private let env = ProcessInfo.processInfo.environment
    private let messages = XCUIApplication(bundleIdentifier: "com.apple.MobileSMS")

    override func setUp() { continueAfterFailure = false }

    private func element(_ format: String, _ arg: String) -> XCUIElement {
        messages.descendants(matching: .any).matching(NSPredicate(format: format, arg)).firstMatch
    }

    private func shot(_ name: String) {
        Thread.sleep(forTimeInterval: 0.8)
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let dir = env["SHOT_DIR"] { try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png")) }
    }

    private func openField() -> XCUIElement {
        messages.terminate()
        messages.launch()
        let search = messages.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 8))
        search.tap()
        let intro = element("label == %@", "Continue")
        if intro.waitForExistence(timeout: 2) { intro.tap() }
        let ours = element("identifier == %@", "pip.more")
        for _ in 0..<5 where !ours.waitForExistence(timeout: 1.5) { element("label == %@", "Next keyboard").tap() }
        XCTAssertTrue(ours.exists, "Pip keyboard not shown")
        return search
    }

    /// Taps Pip's own keys, one by one, switching between letters and numbers as needed.
    private func type(_ text: String) {
        for ch in text {
            if ch == " " { element("identifier == %@", "space").tap(); continue }
            let key = element("label ==[c] %@", String(ch))
            if !(key.exists && key.isHittable) { element("identifier == %@", "pip.more").tap() }
            XCTAssertTrue(key.waitForExistence(timeout: 2) && key.isHittable, "no key \(ch)")
            key.tap()
        }
    }

    private func clear(_ field: XCUIElement) {
        let clear = field.buttons["Clear text"]
        if clear.exists { clear.tap() }
    }

    func testSplitChip() {
        let field = openField()
        type("split 120 4 ways")
        let chip = element("identifier == %@", "chip.explain")
        XCTAssertTrue(chip.waitForExistence(timeout: 5), "no chip")
        XCTAssertEqual(chip.label.lowercased(), "split 120 4 ways: $30.00 each")
        shot("calc-split-chip")
        chip.tap()
        XCTAssertEqual(field.value as? String, "$30.00 each")

        clear(field)
        type("100 usd to inr")
        XCTAssertTrue(chip.waitForExistence(timeout: 8), "no currency chip")
        XCTAssertTrue(chip.label.lowercased().hasPrefix("100 usd to inr: \u{20B9}"), chip.label)
        shot("calc-currency-chip")
    }
}
