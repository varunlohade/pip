import XCTest
@testable import Pip

/// R12: the per-key work on the main thread (decode, commit, autocorrect, smart detection, Fix check, bar state)
/// stays under 8 ms at p95. The same intervals carry os_signposts ("keys" category) for Instruments on a device.
@MainActor
final class KeyTimingTests: XCTestCase {
    func testPerKeyHandlerP95IsUnderEightMilliseconds() async throws {
        let host = FakeHost()
        let model = KeyboardModel(deps: .fake(api: FakeAPI()))
        model.host = host
        model.keyboardAppeared()
        for _ in 0..<1000 where KeyboardModel.language == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(KeyboardModel.language)

        let text = "can we meet friday at 7pm to talk about teh invoice and the plan for next week, i think tomorow works too. "
        var ms: [Double] = []
        var n = 0
        while ms.count < 500 {
            let ch = Array(text)[n % text.count]
            n += 1
            let keys = KeyboardGeometry.keys(layout: model.layout, width: 390, globe: false, currency: "$")
            if ch == "," || ch == "." || ch.isNumber {
                // Punctuation and digits sit on another page: the mode taps are not timed.
                model.activate(keys.first { $0.id == "mode" }!)
            }
            let all = KeyboardGeometry.keys(layout: model.layout, width: 390, globe: false, currency: "$")
            guard let key = all.first(where: { ch == " " ? $0.kind == .space : $0.kind == .char(String(ch).lowercased()) }) else {
                if model.layout != .letters { model.activate(all.first { $0.id == "mode" }!) }
                continue
            }
            let finger = NSObject()
            let id = ObjectIdentifier(finger)
            let p = CGPoint(x: key.frame.midX, y: key.frame.midY)
            let start = ContinuousClock.now
            if let k = model.key(for: id, at: p, in: all) {
                model.touchBegan(id, k, at: p)
                model.touchEnded(id)
            }
            ms.append(Double((ContinuousClock.now - start) / .microseconds(1)) / 1000)
            if model.layout != .letters, ch != " " { model.activate(KeyboardGeometry.keys(layout: model.layout, width: 390, globe: false, currency: "$").first { $0.id == "mode" }!) }
            if host.text.count > 400 { host.text = "" }
            await Task.yield()
        }
        let sorted = ms.sorted()
        let p50 = sorted[sorted.count / 2], p95 = sorted[Int(Double(sorted.count - 1) * 0.95)], worst = sorted.last!
        print(String(format: "PIP_TIMING per_key_ms p50=%.2f p95=%.2f max=%.2f keys=%d", p50, p95, worst, ms.count))
        XCTAssertLessThan(p95, 8)
        model.keyboardDisappeared()
    }
}
