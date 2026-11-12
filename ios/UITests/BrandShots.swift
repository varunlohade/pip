import XCTest

/// B2 screenshots of the real app, against `npm run fake`, with TEST_RUNNER_SHOT_DIR set.
/// test0Hero needs a fresh install (no pairing yet). Then SmartChipShots/test1Setup, ExplainShots, and test6Home last.
final class BrandShots: XCTestCase {
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

    func test0Hero() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(element(app, "hero.add").waitForExistence(timeout: 10), "no hero: \(app.debugDescription.suffix(2000))")
        XCTAssertEqual(element(app, "hero.title").label, "A friend in your keyboard")
        Thread.sleep(forTimeInterval: 1.5)
        shot("b2-1-onboarding")
        element(app, "hero.add").tap()
        let step = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "onboarding.step.")).firstMatch
        XCTAssertTrue(step.waitForExistence(timeout: 5), "no setup step after the hero")
        Thread.sleep(forTimeInterval: 1)
        shot("b2-1b-onboarding-keyboard-step")
    }

    /// Plans typed in a chat become chips; the keyboard keeps them for Home's "From your chats".
    func test5Caught() {
        messages.terminate()
        messages.launch()
        let search = messages.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 8))
        search.tap()
        let ours = element(messages, "pip.more")
        for _ in 0..<5 where !ours.waitForExistence(timeout: 1.5) {
            messages.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Next keyboard")).firstMatch.tap()
        }
        XCTAssertTrue(ours.exists, "Pip keyboard not shown")
        for text in ["dentist friday 10am", "call supplier at 5"] {
            let clear = search.buttons["Clear text"]
            if clear.exists { clear.tap() }
            UIPasteboard.general.string = text
            search.press(forDuration: 1.0)
            let paste = messages.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Paste")).firstMatch
            XCTAssertTrue(paste.waitForExistence(timeout: 4))
            paste.tap()
            let allow = messages.alerts.buttons["Allow Paste"]
            if allow.waitForExistence(timeout: 1) { allow.tap() }
            UIPasteboard.general.items = []
            element(messages, "space").tap()
            let chip = messages.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "chip.smart.")).firstMatch
            XCTAssertTrue(chip.waitForExistence(timeout: 4), "no smart chip for \(text)")
        }
    }

    func test6Home() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(element(app, "home.headline").waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 1.5)
        shot("b2-2-home")
    }
}
