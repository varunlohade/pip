import XCTest

/// TestFlight 0.2 (3) fixes in the app, against `npm run fake`. Run SmartChipShots/test1Setup first (paired, keyboard on
/// with Full Access but not first). test1 shows Home's wallet row with no wallet yet. For test2, reset the simulator
/// keychain first (signed out, keyboard still on): onboarding must see the keyboard and tick its steps.
final class FixShots: XCTestCase {
    private let env = ProcessInfo.processInfo.environment

    override func setUp() { continueAfterFailure = false }

    private func shot(_ name: String) {
        Thread.sleep(forTimeInterval: 0.8)
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let dir = env["SHOT_DIR"] { try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + (env["SHOT_PREFIX"] ?? "") + ".png")) }
    }

    private func id(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@", identifier)).firstMatch
    }

    func test1WalletEmptyState() {
        let app = XCUIApplication()
        app.launch()
        let wallet = id(app, "home.wallet")
        for _ in 0..<4 where !(wallet.exists && wallet.isHittable) { app.swipeUp() }
        XCTAssertTrue(wallet.waitForExistence(timeout: 10), String(app.debugDescription.suffix(3000)))
        let create = NSPredicate(format: "label CONTAINS %@", "Create your NEAR wallet")
        let until = Date().addingTimeInterval(10)
        while !create.evaluate(with: wallet), Date() < until { Thread.sleep(forTimeInterval: 0.3) }
        XCTAssertTrue(create.evaluate(with: wallet), "row says: \(wallet.label)")
        shot("fix-wallet-empty")
    }

    func test2OnboardingSeesTheKeyboard() {
        let app = XCUIApplication()
        app.launch()
        let hero = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Add Pip'")).firstMatch
        if hero.waitForExistence(timeout: 4) { hero.tap() }
        XCTAssertTrue(id(app, "keyboard.on").waitForExistence(timeout: 10), String(app.debugDescription.suffix(3000)))
        XCTAssertTrue(id(app, "keyboard.step.done").exists, "no ticked step")
        shot("fix-onboarding-detected")
    }
}
