import Foundation

/// When typed text goes to /v1/suggest. Only an action-ish sentence the phone could not read goes, once.
///
/// Pure: the caller hands in the text. The only state is the sentences already sent.
struct SuggestPolicy {
    /// Shortcuts start with this. They run on the phone and never go to the server.
    static let shortcutPrefix = ";"
    static let debounce = AppConfig.suggestDebounce

    /// Sentences already sent, by their first words. Each goes once.
    private(set) var askedSentences: Set<String> = []

    init() {}

    /// Text with action-ish signals but no clear on-device match ("can we do Ana's thing Friday"):
    /// the last sentence goes to the server once, after the pause. Nil for plain chat, a clear match, a secret, or a sentence already sent.
    func maybe(_ typed: String, clear: Bool) -> String? {
        guard !clear, !typed.isEmpty, !typed.hasPrefix(Self.shortcutPrefix), SecretScan.scan(typed) == .clean, SmartDetect.maybe(typed) else { return nil }
        let sentence = SmartDetect.lastSentence(typed)
        return askedSentences.contains(Self.sentenceKey(sentence)) ? nil : sentence
    }

    /// Called when the request really goes out, after the pause.
    mutating func markAsked(_ sentence: String) {
        askedSentences.insert(Self.sentenceKey(sentence))
    }

    /// A sentence is known by its first three words, so typing on in the same sentence does not ask again.
    static func sentenceKey(_ sentence: String) -> String {
        sentence.lowercased().split(whereSeparator: \.isWhitespace).prefix(3).joined(separator: " ")
    }
}

/// Text that must not go to a server: card numbers, one-time codes, keys and tokens.
enum SecretScan {
    enum Verdict: Equatable { case clean, cardNumber, code, token }

    static func scan(_ text: String) -> Verdict {
        if hasCardNumber(text) { return .cardNumber }
        let words = text.split(whereSeparator: \.isWhitespace)
        if words.contains(where: { $0.count == 6 && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }) { return .code }
        if text.contains("PRIVATE KEY-----") || words.contains(where: { looksLikeToken(String($0)) }) { return .token }
        return .clean
    }

    /// 13 to 19 digits, single spaces or dashes allowed between them, passing the Luhn check.
    static func hasCardNumber(_ text: String) -> Bool {
        var start = text.startIndex
        while let r = text.range(of: #"[0-9](?:[ -]?[0-9]){12,18}"#, options: .regularExpression, range: start..<text.endIndex) {
            if luhn(text[r].filter(\.isNumber)) { return true }
            start = r.upperBound
        }
        return false
    }

    static func luhn(_ digits: String) -> Bool {
        var sum = 0
        for (i, ch) in digits.reversed().enumerated() {
            var d = ch.wholeNumberValue ?? 0
            if i % 2 == 1 { d *= 2; if d > 9 { d -= 9 } }
            sum += d
        }
        return sum % 10 == 0
    }

    static let keyPrefixes = [
        "sk-", "sk_live_", "sk_test_", "rk_live_", "rk_test_", "whsec_", "xoxb-", "xoxp-", "ghp_", "gho_",
        "github_pat_", "glpat-", "AKIA", "AIza", "ya29.", "npm_", "hf_", "shpat_", "SG.", "pkd_",
    ]

    static func looksLikeToken(_ word: String) -> Bool {
        if word.count >= 16, keyPrefixes.contains(where: { word.hasPrefix($0) }) { return true }
        if word.range(of: #"^eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}$"#, options: .regularExpression) != nil { return true }
        // A long unbroken run of key characters with both letters and digits.
        return word.count >= 32 && word.range(of: #"^[A-Za-z0-9+/=_-]+$"#, options: .regularExpression) != nil
            && word.contains(where: \.isLetter) && word.contains(where: \.isNumber)
    }
}
