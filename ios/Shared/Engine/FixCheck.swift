import NaturalLanguage
import UIKit

/// What the Fix chip offers for the text before the cursor, and the text after the fix, made on the phone.
struct FixPlan: Equatable {
    let title: String
    /// The line beside Undo after the fix went in.
    let done: String
    let fixed: String
}

/// Finds typos, capitals and spacing on the phone, before any tap. Names, links, emails and amounts are never touched.
enum FixCheck {
    enum Spell: Equatable { case ok, wrong(guesses: [String]) }
    typealias Speller = (String) -> Spell

    static let maxChars = 600

    static let slips: [String: String] = [
        "teh": "the", "adn": "and", "taht": "that", "waht": "what", "thier": "their", "recieve": "receive", "u": "you",
        "dont": "don't", "cant": "can't", "wont": "won't", "didnt": "didn't", "doesnt": "doesn't", "isnt": "isn't",
        "wasnt": "wasn't", "arent": "aren't", "couldnt": "couldn't", "wouldnt": "wouldn't", "shouldnt": "shouldn't",
        "havent": "haven't", "hasnt": "hasn't", "im": "I'm", "ive": "I've", "youre": "you're", "theyre": "they're",
        "thats": "that's", "whats": "what's",
    ]
    /// Chat words a spell checker flags but people mean.
    static let chatWords: Set<String> = [
        "ok", "okay", "lol", "pls", "plz", "thx", "btw", "omg", "np", "hmm", "haha", "yeah", "yep", "nope", "gonna",
        "wanna", "gotta", "asap", "fyi", "eta", "tbh", "idk", "ya", "sry", "tmrw", "rn", "lmk", "omw", "ngl", "brb",
    ]
    static let questionWords: Set<String> = [
        "can", "could", "will", "would", "do", "does", "did", "is", "are", "was", "were", "when", "what", "where", "who",
        "how", "why", "which", "should", "shall", "may",
    ]
    /// Everyday English words, most used first. A guess from this list marks a typo, not another language.
    static let commonWords: [String] = [
        "the", "be", "to", "of", "and", "a", "in", "that", "have", "i", "it", "for", "not", "on", "with", "he", "as",
        "you", "do", "at", "this", "but", "his", "by", "from", "they", "we", "say", "her", "she", "or", "an", "will",
        "my", "one", "all", "would", "there", "their", "what", "so", "up", "out", "if", "about", "who", "get", "which",
        "go", "me", "when", "make", "can", "like", "time", "no", "just", "him", "know", "take", "people", "into",
        "year", "your", "good", "some", "could", "them", "see", "other", "than", "then", "now", "look", "only", "come",
        "its", "over", "think", "also", "back", "after", "use", "two", "how", "our", "work", "first", "well", "way",
        "even", "new", "want", "because", "any", "these", "give", "day", "most", "us", "is", "are", "was", "were",
        "been", "has", "had", "did", "does", "should", "here", "where", "why", "very", "much", "more", "really",
        "right", "next", "last", "still", "again", "before", "soon", "later", "today", "tomorrow", "tonight",
        "morning", "week", "thanks", "thank", "please", "sorry", "yes", "sure", "send", "sent", "invoice", "pay",
        "paid", "money", "bill", "price", "call", "tell", "ask", "need", "let", "meet", "help", "done", "ready",
        "free", "busy", "great", "nice", "hope", "wait", "check", "available", "appointment", "booking", "receipt",
    ]
    private static let commonRank = Dictionary(commonWords.enumerated().map { ($1, $0) }, uniquingKeysWith: min)

    /// `names`: names to leave as typed, never flagged. `skipLast`: the last word is still being typed, so leave it alone.
    static func plan(_ text: String, names: [String] = [], skipLast: Bool = false, spell: Speller = system) -> FixPlan? {
        guard !text.isEmpty, text.count <= maxChars else { return nil }
        let known = Set(names.flatMap { $0.lowercased().split(separator: " ").map(String.init) })
        var chunks = split(text)
        let lastWord = chunks.lastIndex { !$0.space }
        var typos: [(String, String)] = [], capitals = 0, spacing = 0, checked = 0, unknown = 0, commonGuess = false
        var atStart = true
        for i in chunks.indices {
            if chunks[i].space {
                if chunks[i].text.count > 1, chunks[i].text.allSatisfy({ $0 == " " }) { chunks[i].text = " "; spacing += 1 }
                continue
            }
            let parts = pieces(chunks[i].text)
            let ends = chunks[i].text.last.map { ".!?".contains($0) } ?? false
            defer { atStart = ends }
            guard !(skipLast && i == lastWord), !parts.core.isEmpty, isWord(parts.core) else { continue }
            var word = parts.core
            let lower = word.lowercased()
            if lower == "i" || lower.hasPrefix("i'") || lower.hasPrefix("i\u{2019}") {
                if word.first == "i" { word = "I" + word.dropFirst(); capitals += 1 }
            } else if let fix = slips[lower] {
                let out = word.first!.isUppercase || atStart ? fix.prefix(1).uppercased() + fix.dropFirst() : fix
                typos.append((word, String(out)))
                word = String(out)
            } else if lower.count >= 3, !known.contains(lower), !chatWords.contains(lower), !CryptoWords.keep(word),
                      !word.dropFirst().contains(where: \.isUppercase), atStart || !word.first!.isUppercase {
                checked += 1
                if case .wrong(let guesses) = spell(word) {
                    unknown += 1
                    let near = guesses.filter { !$0.contains(" ") && distance(lower, $0.lowercased()) <= 2 }
                    let common = near.filter { commonRank[$0.lowercased()] != nil }
                        .min { commonRank[$0.lowercased()]! < commonRank[$1.lowercased()]! }
                    if common != nil { commonGuess = true }
                    if let guess = common ?? near.first {
                        let out = word.first!.isUppercase ? guess.prefix(1).uppercased() + guess.dropFirst() : guess
                        typos.append((word, out))
                        word = out
                    }
                }
            }
            if atStart, let f = word.first, f.isLowercase {
                word = f.uppercased() + word.dropFirst()
                capitals += 1
            }
            chunks[i].text = parts.lead + word + parts.trail
        }
        // Another language, not typos: mostly unknown words with no everyday English word close by,
        // or text the recognizer is sure is not English (Spanish words are mostly in the English dictionary).
        if checked >= 3, unknown * 10 >= checked * 7, !commonGuess { return nil }
        if checked >= 3, otherLanguage(text) { return nil }
        guard !typos.isEmpty || capitals > 0 || spacing > 0 else { return nil }
        var fixed = chunks.map(\.text).joined()
        if let last = fixed.last, last.isLetter, let l = lastWord, isWord(pieces(chunks[l].text).core) {
            let clause = fixed.split(whereSeparator: { ",.!?;".contains($0) }).last ?? ""
            let first = clause.split(separator: " ").first.map { $0.lowercased() } ?? ""
            fixed += questionWords.contains(first) ? "?" : "."
        }
        if typos.count == 1, let t = typos.first, t.0.count + t.1.count <= 14 {
            return FixPlan(title: "Fix \u{201C}\(t.0)\u{201D} \u{2192} \u{201C}\(t.1)\u{201D}", done: "Fixed 1 typo \u{2713}", fixed: fixed)
        }
        if !typos.isEmpty {
            let n = typos.count == 1 ? "1 typo" : "\(typos.count) typos"
            return FixPlan(title: "Fix \(n)", done: "Fixed \(n) \u{2713}", fixed: fixed)
        }
        if capitals > 0 { return FixPlan(title: "Fix capitals", done: "Fixed capitals \u{2713}", fixed: fixed) }
        return FixPlan(title: "Fix spacing", done: "Fixed spacing \u{2713}", fixed: fixed)
    }

    /// What space or punctuation puts in place of the word that ends `before`, or nil. Clear typos only: a known slip,
    /// a lone "i", or a misspelling whose close guess is an everyday word. The same words as `plan` are never touched:
    /// names, links, emails, amounts, chat words and other languages. `kept`: words the owner put back after a fix.
    /// `decode`: the touch decoder's word for the lowercased typed word, tried before the spell checker's guesses.
    static func autocorrect(_ before: String, names: [String] = [], kept: Set<String> = [], spell: Speller = system,
                            decode: ((String) -> String?)? = nil) -> (typed: String, fixed: String)? {
        let token = String(before.reversed().prefix { !$0.isWhitespace }.reversed())
        guard !token.isEmpty, token.count <= 30 else { return nil }
        let parts = pieces(token)
        let word = parts.core, lower = word.lowercased()
        guard !word.isEmpty, parts.trail.isEmpty, isWord(word), !kept.contains(lower) else { return nil }
        let head = before.dropLast(token.count).trimmingCharacters(in: .whitespaces)
        let atStart = head.isEmpty || head.last.map { $0.isNewline || ".!?".contains($0) } == true
        func cased(_ fix: String) -> String { word.first!.isUppercase || atStart ? fix.prefix(1).uppercased() + fix.dropFirst() : fix }
        if lower == "i" { return word == "I" ? nil : (word, "I") }
        if lower.hasPrefix("i'") || lower.hasPrefix("i\u{2019}") {
            return word.first == "i" ? (word, "I" + word.dropFirst()) : nil
        }
        if let fix = slips[lower], lower.count > 1 { return (word, cased(fix)) }
        let known = Set(names.flatMap { $0.lowercased().split(separator: " ").map(String.init) })
        guard lower.count >= 2, !known.contains(lower), !chatWords.contains(lower), !CryptoWords.keep(word),
              !word.dropFirst().contains(where: \.isUppercase), atStart || !word.first!.isUppercase,
              case .wrong(let guesses) = spell(word) else { return nil }
        let most = lower.count >= 5 ? 2 : 1
        let common = lower.count < 3 ? nil : guesses.filter({ !$0.contains(" ") && distance(lower, $0.lowercased()) <= most && commonRank[$0.lowercased()] != nil })
            .min(by: { commonRank[$0.lowercased()]! < commonRank[$1.lowercased()]! })
        guard let guess = decode?(lower) ?? common else { return nil }
        let sentence = String(head.split(whereSeparator: { ".!?\n".contains($0) }).last ?? "") + " " + word
        if sentence.split(separator: " ").count >= 3, otherLanguage(sentence) { return nil }
        return (word, cased(guess.lowercased()))
    }

    /// The system spell checker, in English. A word it has no guess for comes back `.wrong(guesses: [])`.
    static func system(_ word: String) -> Spell {
        let checker = UITextChecker()
        let range = NSRange(location: 0, length: (word as NSString).length)
        let bad = checker.rangeOfMisspelledWord(in: word, range: range, startingAt: 0, wrap: false, language: "en_US")
        guard bad.location != NSNotFound else { return .ok }
        return .wrong(guesses: checker.guesses(forWordRange: bad, in: word, language: "en_US") ?? [])
    }

    static func otherLanguage(_ text: String) -> Bool {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let (language, p) = recognizer.languageHypotheses(withMaximum: 1).first else { return false }
        return language != .english && p >= 0.9
    }

    private struct Chunk { var text: String; let space: Bool }

    private static func split(_ text: String) -> [Chunk] {
        var out: [Chunk] = []
        for ch in text {
            let space = ch.isWhitespace
            if let last = out.last, last.space == space { out[out.count - 1].text.append(ch) } else { out.append(Chunk(text: String(ch), space: space)) }
        }
        return out
    }

    /// Leading and trailing punctuation, and the word between. Links, emails, handles and amounts have an empty core.
    private static func pieces(_ chunk: String) -> (lead: String, core: String, trail: String) {
        let lower = chunk.lowercased()
        if chunk.contains(where: { $0.isNumber || "@#$/\u{20AC}\u{00A3}".contains($0) }) || lower.contains("www.") {
            return ("", "", chunk)
        }
        let isEdge = { (c: Character) in !c.isLetter && c != "'" && c != "\u{2019}" }
        let lead = String(chunk.prefix(while: isEdge))
        let rest = chunk.dropFirst(lead.count)
        let trail = String(rest.reversed().prefix(while: isEdge).reversed())
        let core = String(rest.dropLast(trail.count))
        // "site.com" or "a.b": a dot inside is a link or an abbreviation.
        if core.contains(".") { return ("", "", chunk) }
        return (lead, core, trail)
    }

    private static func isWord(_ s: String) -> Bool { s.allSatisfy { $0.isLetter || $0 == "'" || $0 == "\u{2019}" } }

    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var prev = row[0]
            row[0] = i
            for j in stride(from: 1, through: b.count, by: 1) {
                let cur = row[j]
                row[j] = a[i - 1] == b[j - 1] ? prev : min(prev, row[j], row[j - 1]) + 1
                prev = cur
            }
        }
        return row[b.count]
    }
}
