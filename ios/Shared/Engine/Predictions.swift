import Foundation

/// The iOS-style word row while a word is typed: the word as typed, in quotes, then what space would fix it to,
/// then completions. A tap puts that word in place of the typed one, with a space.
enum Predictions {
    struct Slot: Equatable {
        let title: String
        let word: String
    }

    /// The word being typed at the end of `before`, or nil mid-link, mid-amount or after a space.
    static func typedWord(_ before: String) -> String? {
        let token = String(before.reversed().prefix { !$0.isWhitespace }.reversed())
        guard !token.isEmpty, token.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "\u{2019}" }) else { return nil }
        return token
    }

    /// `learned`: words this person typed and kept, lowercased; their completions come first.
    static func slots(typed: String, correction: String?, completions: [String], learned: Set<String> = []) -> [Slot] {
        let lower = typed.lowercased()
        let capital = typed.first?.isUppercase == true
        func cased(_ w: String) -> String { capital ? w.prefix(1).uppercased() + w.dropFirst() : w }
        var out = [Slot(title: "\u{201C}\(typed)\u{201D}", word: typed)]
        var seen: Set<String> = [lower]
        let mine = learned.filter { $0.hasPrefix(lower) && $0 != lower }.sorted()
        for w in [correction].compactMap({ $0 }) + (mine + completions).map(cased) where out.count < 3 {
            guard seen.insert(w.lowercased()).inserted else { continue }
            out.append(Slot(title: w, word: w))
        }
        return out
    }
}
