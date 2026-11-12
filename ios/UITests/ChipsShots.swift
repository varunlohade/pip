import XCTest

/// The chip ✕ and the streamed Rewrite list in the real Pip keyboard, in the Messages search field.
/// Run SmartChipShots/test1Setup first (pairs with `npm run fake`). TEST_RUNNER_SHOT_DIR saves the screenshots.
final class ChipsShots: XCTestCase {
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

    private func type(_ text: String) {
        for ch in text {
            if ch == " " { element("identifier == %@", "space").tap(); continue }
            let key = element("label ==[c] %@", String(ch))
            if !(key.exists && key.isHittable) { element("identifier == %@", "pip.more").tap() }
            XCTAssertTrue(key.waitForExistence(timeout: 2) && key.isHittable, "no key \(ch)")
            key.tap()
        }
    }

    func testDismissAndRewriteList() {
        let field = openField()
        type("split 120 4 ways")
        let dismiss = element("identifier == %@", "chip.dismiss")
        XCTAssertTrue(dismiss.waitForExistence(timeout: 5), "no ✕ on the chip")
        shot("chip-with-dismiss")
        dismiss.tap()
        XCTAssertFalse(element("identifier == %@", "chip.explain").waitForExistence(timeout: 1), "the chip stays away after ✕")

        field.buttons["Clear text"].tap()
        type("call supplier at 5 ")  // a chip keeps the word slots off the bar, so the Rewrite button shows
        XCTAssertTrue(element("identifier == %@", "write.toggle").waitForExistence(timeout: 5))
        element("identifier == %@", "write.toggle").tap()
        XCTAssertTrue(element("identifier == %@", "write.row.polite").waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1)
        shot("rewrite-list")
        element("identifier == %@", "write.row.shorter").tap()
        XCTAssertFalse(element("identifier == %@", "write.row.polite").exists, "a tap puts the version in and closes the list")
    }
}
