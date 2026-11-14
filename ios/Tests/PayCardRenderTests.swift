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
        var card = PayPanel(intent: .fake(draft))
        card.pinReady = true
        var sent = PayPanel(intent: .fake(draft, status: "sent"))
        sent.phase = .sent
        var pin = card
        pin.pin = "48"
        var fail = card
        fail.note = PayFallback.locked
        var first = PayPanel(intent: .fake(draft, newRecipient: true))
        first.pinReady = true
        first.note = PayFallback.pickEnd
        for (prefix, width) in [("pay", CGFloat(393)), ("pay-se", CGFloat(375))] {
            for dark in [false, true] {
                let mode = dark ? "dark" : "light"
                try render("\(prefix)-\(mode)-card", width: width, dark: dark, card)
                try render("\(prefix)-\(mode)-sent", width: width, dark: dark, sent)
                try render("\(prefix)-\(mode)-pin", width: width, dark: dark, pin)
                try render("\(prefix)-\(mode)-fail", width: width, dark: dark, fail)
                try render("\(prefix)-\(mode)-first", width: width, dark: dark, first)
            }
        }
    }
    private static let implicit = "9f3c0a7be2d14c6a8b5e0f2d7c19a4e6b3f8d2c5a7e1b9f4d6c3a8e2b7f5d1c9"
    private func firstTime(_ to: String, note: Bool = false) -> PayPanel {
        var p = PayPanel(intent: .fake(PayDraft(amount: "5", token: "USDC", recipient: to, trigger: ""), newRecipient: true))
        p.pinReady = true
        if note { p.note = PayFallback.pickEnd }
        return p
    }

    /// The new-address check fits the grown keyboard on an SE and an iPhone 16, with the longest addresses and the note line.
    func testAddressCheckFitsTheKeyboard() {
        for width in [CGFloat(375), 393] {
            let room = Theme.SystemKeyboard.addressCheckHeight - Theme.SystemKeyboard.barHeight - Theme.SystemKeyboard.sizes(for: width).bottomInset
            for to in [Self.implicit, TestXchain.evm, "pipfundmwg9zj4l.testnet"] {
                for note in [false, true] {
                    let panel = firstTime(to, note: note)
                    XCTAssertEqual(KeyboardModel.payHeight(panel), Theme.SystemKeyboard.addressCheckHeight)
                    let card = UIHostingController(rootView: PayKeyboardCard(panel: panel, approve: {}, reject: {}, insert: {})
                        .frame(width: width).fixedSize(horizontal: false, vertical: true))
                    let h = card.sizeThatFits(in: CGSize(width: width, height: 2000)).height
                    XCTAssertLessThanOrEqual(h, room, "\(to) at \(width), note \(note): \(h) > \(room)")
                }
            }
        }
        var done = firstTime(TestXchain.evm)
        let right = done.confirm?.answer
        done.confirm?.picked = right
        XCTAssertEqual(KeyboardModel.payHeight(done), Theme.SystemKeyboard.calendarHeight, "back to the pay height once picked")
    }

    /// The address wraps onto more lines instead of being cut: 64 characters at SE width take 2 or more lines, none wider than the card.
    func testFullAddressWrapsAndIsNeverCut() {
        func size(_ a: String) -> CGSize {
            UIHostingController(rootView: FullAddress(confirm: AddressConfirm(a)).frame(width: 343).fixedSize(horizontal: false, vertical: true))
                .sizeThatFits(in: CGSize(width: 343, height: 2000))
        }
        let one = size("abcd"), long = size(Self.implicit)
        XCTAssertLessThanOrEqual(long.width, 343)
        XCTAssertGreaterThan(long.height, one.height + 10, "64 characters wrap: \(one.height) vs \(long.height)")
    }

    /// docs/shots/first-time-full-address.png: iPhone 16 and SE, light and dark, a .testnet name, an EVM address and a 64-character account (with the note line).
    func testRenderFirstTimeFullAddress() throws {
        guard let dir = ProcessInfo.processInfo.environment["SHOT_DIR"] else { throw XCTSkip("SHOT_DIR not set") }
        func board(_ panel: PayPanel, width: CGFloat, dark: Bool) -> some View {
            let model = KeyboardModel(deps: .fake(api: FakeAPI()))
            model.isDark = dark
            model.payPanel = panel
            return KeyboardView(model: model).frame(width: width)
        }
        let rows: [(String, CGFloat, PayPanel, PayPanel)] = [
            ("iPhone 16", 393, firstTime("pipfundmwg9zj4l.testnet"), firstTime(TestXchain.evm)),
            ("iPhone SE", 375, firstTime(Self.implicit, note: true), firstTime(TestXchain.evm, note: true)),
        ]
        let sheet = VStack(alignment: .leading, spacing: 16) {
            ForEach(rows, id: \.0) { name, width, a, b in
                Text(name).font(.system(size: 20, weight: .semibold))
                HStack(alignment: .top, spacing: 16) {
                    board(a, width: width, dark: false)
                    board(a, width: width, dark: true)
                    board(b, width: width, dark: false)
                    board(b, width: width, dark: true)
                }
            }
        }
        .padding(16).background(Color.white)
        let r = ImageRenderer(content: sheet)
        r.scale = 2
        let png = try XCTUnwrap(r.uiImage?.pngData())
        try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("first-time-full-address.png"))
    }
}
