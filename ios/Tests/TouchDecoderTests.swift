import XCTest
@testable import Pip

/// The touch decoder: key resizing, adaptation, word decode, and a harness that measures typing errors.
final class TouchDecoderTests: XCTestCase {
    static let model = LanguageModel.bundled()!
    private let caps = KeyboardGeometry.keys(layout: .letters, width: 390, globe: false, currency: "$")
    private var keys: [TouchKey] { KeyboardGeometry.touchKeys(caps) }
    private func key(_ c: Character) -> TouchKey { keys.first { $0.letter == c }! }

    func testTheBundledModelLoadsAndKnowsEnglish() {
        let m = Self.model
        XCTAssertTrue(m.contains("the"))
        XCTAssertTrue(m.contains("invoice"))
        XCTAssertFalse(m.contains("teh"))
        XCTAssertTrue(m.hasPrefix("invo"))
        XCTAssertFalse(m.hasPrefix("qzx"))
        XCTAssertGreaterThan(m.logP("u", after: "q"), m.logP("z", after: "q"))
        XCTAssertGreaterThan(m.logP("e", after: "th"), m.logP("w", after: "th"))
    }

    func testATapInsideAKeysCoreIsNeverChanged() {
        // After "q", the model wants "u"; a tap well inside "y" still types "y", every time.
        let y = key("y")
        for fx in stride(from: 0.21, through: 0.79, by: 0.058) {
            for fy in stride(from: 0.21, through: 0.79, by: 0.058) {
                let p = CGPoint(x: y.frame.minX + fx * y.frame.width, y: y.frame.minY + fy * y.frame.height)
                XCTAssertEqual(TouchDecoder.decode(p, keys: keys, word: "q", model: Self.model)?.key.letter, "y", "\(fx),\(fy)")
            }
        }
    }

    func testAnEdgeTapGoesToTheLikelyLetter() {
        // On the edge between "y" and "u", after "q": "u".
        let y = key("y"), u = key("u")
        let edge = CGPoint(x: (y.frame.maxX + u.frame.minX) / 2 - 3, y: y.frame.midY)
        XCTAssertEqual(KeyboardGeometry.key(at: edge, in: caps)?.kind, .char("y"))
        XCTAssertEqual(TouchDecoder.decode(edge, keys: keys, word: "q", model: Self.model)?.key.letter, "u")
        // With no letter model, the touch alone decides: "y".
        XCTAssertEqual(TouchDecoder.decode(edge, keys: keys, word: "", model: nil)?.key.letter, "y")
    }

    func testTheCandidatesAreTheThreeLikeliestByTouch() {
        let g = key("g")
        let r = TouchDecoder.decode(CGPoint(x: g.frame.midX, y: g.frame.midY), keys: keys, word: "", model: Self.model)!
        XCTAssertEqual(r.candidates.count, 3)
        XCTAssertEqual(r.candidates.first?.letter, "g")
        XCTAssertGreaterThan(r.candidates[0].probability, r.candidates[1].probability)
    }

    func testAdaptationLearnsALowTapAndStaysClamped() {
        var a = TouchAdaptation()
        let s = key("s")
        for _ in 0..<500 { a.learn(CGPoint(x: s.frame.midX + 2 * s.frame.width, y: s.frame.maxY + 3 * s.frame.height), on: s) }
        XCTAssertEqual(a.offset(row: 1).dx, CGFloat(TouchAdaptation.maxX), accuracy: 1e-9)
        XCTAssertEqual(a.offset(row: 1).dy, CGFloat(TouchAdaptation.maxY), accuracy: 1e-9)
        XCTAssertEqual(a.offset(row: 0).dx, 0)
        XCTAssertEqual(TouchAdaptation(stored: a.stored), a)
        XCTAssertEqual(TouchAdaptation(stored: [9, 9, 9, -9, -9, -9]).offset(row: 2).dy, -CGFloat(TouchAdaptation.maxY))
        XCTAssertEqual(TouchAdaptation(stored: [1]), TouchAdaptation())
    }

    func testWordDecodeFixesANearMissAndKeepsRealWords() {
        let m = Self.model
        XCTAssertEqual(TouchDecoder.correctWord("availble", taps: nil, model: m), "available")
        XCTAssertEqual(TouchDecoder.correctWord("tomorow", taps: nil, model: m), "tomorrow")
        XCTAssertNil(TouchDecoder.correctWord("invoice", taps: nil, model: m))
        XCTAssertNil(TouchDecoder.correctWord("arpit", taps: nil, model: m))
        XCTAssertNil(TouchDecoder.correctWord("a", taps: nil, model: m))
        // "thw": the taps say the last key could have been "e".
        let taps: [[TouchDecoder.Candidate]] = [[.init(letter: "t", probability: 0.9)], [.init(letter: "h", probability: 0.9)],
                                                 [.init(letter: "w", probability: 0.55), .init(letter: "e", probability: 0.4)]]
        XCTAssertEqual(TouchDecoder.correctWord("thw", taps: taps, model: m), "the")
    }
}
