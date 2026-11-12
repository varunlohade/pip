import Foundation

/// Next-word guesses after a space: words this person typed after the last word in this session first,
/// then a small table of common English follow-ups, then everyday words. Pure; nothing leaves the phone or is saved.
struct NextWord {
    /// The last word before the cursor, lowercased, then the words seen after it, with counts.
    private(set) var seen: [String: [String: Int]] = [:]

    static let follows: [String: [String]] = [
        "i": ["am", "will", "think"], "i'm": ["not", "going", "so"], "you": ["are", "can", "want"],
        "we": ["are", "can", "will"], "they": ["are", "were", "will"], "it": ["is", "was", "will"],
        "it's": ["a", "not", "the"], "that": ["is", "was", "would"], "this": ["is", "one", "week"],
        "is": ["it", "the", "a"], "are": ["you", "we", "they"], "was": ["a", "the", "just"],
        "the": ["best", "same", "first"], "a": ["lot", "few", "good"], "an": ["hour", "idea", "email"],
        "to": ["the", "be", "do"], "of": ["the", "my", "course"], "in": ["the", "a", "my"],
        "on": ["the", "my", "it"], "at": ["the", "home", "work"], "for": ["the", "you", "me"],
        "with": ["you", "me", "the"], "and": ["I", "the", "then"], "but": ["I", "it", "the"],
        "can": ["you", "I", "we"], "could": ["you", "we", "be"], "will": ["be", "you", "do"],
        "would": ["you", "be", "like"], "do": ["you", "it", "we"], "did": ["you", "it", "they"],
        "have": ["a", "you", "to"], "has": ["been", "a", "to"], "had": ["a", "to", "been"],
        "see": ["you", "it", "the"], "let": ["me", "us", "you"], "let's": ["go", "do", "meet"],
        "thank": ["you", "God", "goodness"], "thanks": ["for", "so", "again"], "how": ["are", "about", "is"],
        "what": ["is", "are", "do"], "when": ["is", "are", "you"], "where": ["are", "is", "do"],
        "good": ["morning", "night", "luck"], "see you": ["soon", "tomorrow", "later"], "my": ["name", "phone", "friend"],
        "going": ["to", "home", "out"], "want": ["to", "it", "a"], "need": ["to", "a", "it"],
        "call": ["me", "you", "it"], "on my": ["way", "phone", "own"], "be": ["there", "a", "the"],
        "not": ["sure", "a", "yet"], "so": ["much", "I", "good"], "just": ["a", "got", "wanted"],
        "me": ["know", "a", "to"], "know": ["what", "if", "how"], "please": ["let", "send", "call"],
        "send": ["me", "it", "you"], "tomorrow": ["at", "morning", "is"], "today": ["is", "at", "I"],
    ]
    /// After a sentence ends, or in an empty field.
    static let starters = ["I", "The", "Thanks"]
    /// Mid-sentence, when nothing above knows the word.
    static let everyday = ["the", "to", "and"]

    /// Three guesses for the word after `before`, which ends in a space. Empty when `before` does not end in a space.
    func guesses(_ before: String) -> [String] {
        guard before.isEmpty || before.last?.isWhitespace == true else { return [] }
        let head = before.trimmingCharacters(in: .whitespaces)
        if head.isEmpty || head.last.map({ $0.isNewline || ".!?".contains($0) }) == true { return Self.starters }
        let words = head.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard let last = words.last, last.allSatisfy({ $0.isLetter || $0 == "'" }) else { return Self.everyday }
        let pair = words.count >= 2 ? words[words.count - 2] + " " + last : ""
        var out: [String] = []
        let mine = (seen[last] ?? [:]).sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
        for w in mine + (Self.follows[pair] ?? []) + (Self.follows[last] ?? []) + Self.everyday where out.count < 3 {
            if !out.contains(where: { $0.lowercased() == w.lowercased() }) { out.append(w) }
        }
        return out
    }

    /// Learns the pair that ends `before` ("see you " learns "see" → "you"). Call after a word is finished.
    mutating func learn(_ before: String) {
        let words = before.lowercased().split(whereSeparator: \.isWhitespace).map { $0.trimmingCharacters(in: .punctuationCharacters) }
        guard words.count >= 2, let next = words.last, let prev = words.dropLast().last,
              !next.isEmpty, !prev.isEmpty, next.allSatisfy(\.isLetter), prev.allSatisfy({ $0.isLetter || $0 == "'" }) else { return }
        seen[prev, default: [:]][next, default: 0] += 1
    }
}
