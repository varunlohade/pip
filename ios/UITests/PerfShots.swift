import XCTest

/// Lag numbers for the app (TestFlight 0.2 (3): "lag whenever I click on shortcuts"). Needs a paired app on Home.
/// Run on a simulator; compare runs on the same simulator only.
final class PerfShots: XCTestCase {
    private func id(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@", identifier)).firstMatch
    }

    private var options: XCTMeasureOptions {
        let o = XCTMeasureOptions()
        o.iterationCount = 5
        return o
    }

    /// Home › Shortcuts › back, as the owner taps it: open time, close time, and hitches during the push and pop.
    func testShortcutsOpenAndBack() {
        let app = XCUIApplication()
        app.launch()
        let open = id(app, "nav.shortcuts")
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        measure(metrics: [XCTClockMetric(), XCTCPUMetric(application: app)], options: options) {
            open.tap()
            XCTAssertTrue(id(app, "shortcuts.new").waitForExistence(timeout: 5))
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(open.waitForExistence(timeout: 5))
        }
    }

    /// Flings on Home: the sky and the cards scroll. The app's CPU time says how much work each frame costs.
    func testHomeScroll() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(id(app, "nav.shortcuts").waitForExistence(timeout: 10))
        measure(metrics: [XCTCPUMetric(application: app)], options: options) {
            app.swipeUp(velocity: .fast)
            app.swipeDown(velocity: .fast)
        }
    }
}
