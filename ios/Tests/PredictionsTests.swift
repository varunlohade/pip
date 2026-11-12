import XCTest
@testable import Pip

/// The word slots: typed word in quotes, the fix, completions.
final class PredictionsTests: XCTestCase {
    func testTheTypedWordIsOnlyAPlainWordAtTheCursor() {
        XCTAssertEqual(Predictions.typedWord("see you tom"), "tom")
        XCTAssertEqual(Predictions.typedWord("I don't"), "don't")
        XCTAssertNil(Predictions.typedWord("see you "))
        XCTAssertNil(Predictions.typedWord(""))
        XCTAssertNil(Predictions.typedWord("it is $45"))
        XCTAssertNil(Predictions.typedWord("mail sam@x"))
    }

    func testSlotsAreTypedThenFixThenCompletions() {
        let s = Predictions.slots(typed: "tomorow", correction: "tomorrow", completions: ["tomorrows"])
        XCTAssertEqual(s.map(\.title), ["\u{201C}tomorow\u{201D}", "tomorrow", "tomorrows"])
        XCTAssertEqual(s.map(\.word), ["tomorow", "tomorrow", "tomorrows"])
    }

    func testSlotsSkipRepeatsAndFollowTheCapital() {
        let s = Predictions.slots(typed: "Th", correction: nil, completions: ["the", "th", "that", "this"])
        XCTAssertEqual(s.map(\.word), ["Th", "The", "That"])
    }

    func testLearnedWordsComeFirst() {
        let s = Predictions.slots(typed: "sa", correction: nil, completions: ["said", "same"], learned: ["samm"])
        XCTAssertEqual(s.map(\.word), ["sa", "samm", "said"])
    }

    func testCompletionsAreTheCommonestWords() {
        let m = TouchDecoderTests.model
        XCTAssertEqual(Set(m.completions("th", limit: 3)), ["the", "that", "this"])
        XCTAssertEqual(m.completions("invoi", limit: 3).first, "invoice")
        XCTAssertEqual(m.completions("qzx", limit: 3), [])
    }
}
