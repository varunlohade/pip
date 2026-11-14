import Foundation

/// When chips may show and when they stay away. A chip that no longer applies leaves at once; only new ones wait.
enum ChipTiming {
    /// A new chip shows once the fingers have been still this long after a space, punctuation or digits.
    static let settle: Duration = .milliseconds(400)
    /// In the middle of a word the wait is longer, so a half-typed word is not covered.
    static let settleMidWord: Duration = .milliseconds(1000)
    /// The router asks once the fingers have been still this long after a space or punctuation, or longer mid-word.
    static let routePause: Duration = .milliseconds(450)
    static let routePauseMidWord: Duration = .milliseconds(1100)
    /// After ✕: no chip of any kind for this long, and the same text never brings one back.
    static let dismissQuiet: TimeInterval = 10
    /// Typing on past a chip seen for `typedPastSeen` by `typedPastWords` new words: no chip for this long.
    static let typedPastQuiet: TimeInterval = 5
    static let typedPastSeen: TimeInterval = 1
    static let typedPastWords = 2
    /// "Use copied message" shows for this long after the keyboard first saw the copy, once.
    static let copiedLife: TimeInterval = 180

    /// Mid-word means a plain word is still being typed. A space, punctuation, or a token with digits ("7pm", "2+5") is a boundary.
    static func settle(after before: String) -> Duration {
        let word = before.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? ""
        let midWord = before.last.map { !$0.isWhitespace } == true && !word.isEmpty && word.allSatisfy { $0.isLetter || $0 == "'" }
        return midWord ? settleMidWord : settle
    }

    static func routeWait(after before: String) -> Duration { settle(after: before) == settleMidWord ? routePauseMidWord : routePause }

    static func words(_ text: String) -> Int { text.split(whereSeparator: \.isWhitespace).count }
}
