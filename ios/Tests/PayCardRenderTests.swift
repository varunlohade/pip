import SwiftUI
import XCTest
@testable import Pip

/// Renders the real KeyboardView with a pay card, light and dark, at iPhone 16 (393 pt) and SE (375 pt) widths.
/// Runs only with SHOT_DIR set (TEST_RUNNER_SHOT_DIR for xcodebuild); writes pay-{light,dark}-{card,sent,pin,fail}.png.
@MainActor
final class PayCardRenderTests: XCTestCase {
    private func render(_ name: String, width: CGFloat, dark: Bool, _ panel: PayPanel) throws {
        guard let dir = ProcessInfo.processInfo.environment["SHOT_DIR"] else { throw XCTSkip("SHOT_DIR not set") }
        let model = KeyboardModel(deps: .fake(api: FakeAPI()))
        model.isDark = dark
        model.payPanel = panel
        let view = KeyboardView(model: model).frame(width: width)
        let r = ImageRenderer(content: view)
        r.scale = 3
        let png = try XCTUnwrap(r.uiImage?.pngData())
        try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
    }

    private var draft: PayDraft { PayDraft(amount: "5", token: "USDC", recipient: "ana.testnet", trigger: "") }

    func testRenderPayCards() throws {
        let card = PayPanel(intent: .fake(draft))
        var sent = PayPanel(intent: .fake(draft, status: "sent"))
        sent.phase = .sent
        var pin = card
        pin.pin = "48"
        pin.note = PayFallback.usePIN
        var fail = card
        fail.note = PayFallback.useApp
        fail.offerApp = true
        for (prefix, width) in [("pay", CGFloat(393)), ("pay-se", CGFloat(375))] {
            for dark in [false, true] {
                let mode = dark ? "dark" : "light"
                try render("\(prefix)-\(mode)-card", width: width, dark: dark, card)
                try render("\(prefix)-\(mode)-sent", width: width, dark: dark, sent)
                try render("\(prefix)-\(mode)-pin", width: width, dark: dark, pin)
                try render("\(prefix)-\(mode)-fail", width: width, dark: dark, fail)
            }
        }
    }
}
