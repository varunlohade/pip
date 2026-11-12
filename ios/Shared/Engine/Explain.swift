import Foundation

/// "what does btw mean", "explain log function": read on the phone from the last sentence typed. Pure, no network.
/// A term goes to the bundled dictionary first; only a miss or a topic goes to the server.
enum Explain {
    enum Kind: Equatable {
        /// A word or short phrase: "btw", "no cap". The dictionary answers it, or the server on a miss.
        case term
        /// Anything to explain: "log function", "compound interest". Only the server answers it.
        case topic
    }

    struct Ask: Equatable {
        let kind: Kind
        /// The words to explain, lowercased: "btw", "log function". The bar shows them quoted.
        let subject: String
        /// The sentence as typed, sent to the server on a miss.
        let question: String
        /// A term the server may answer when the dictionary has no entry. False for a weak form such as "X meaning".
        var askServerOnMiss = true
    }

    static let maxQuestion = 200

    /// Words that end a subject before it starts: "explain later", "what does it mean", "what's up".
    static let stopWords: Set<String> = [
        "it", "this", "that", "these", "those", "there", "here", "what", "which", "who", "why", "how",
        "i", "me", "my", "you", "your", "yours", "u", "ur", "ya", "he", "him", "his", "she", "her", "they", "them", "their",
        "we", "us", "our", "yourself", "myself", "everything", "anything", "something", "nothing", "all",
        "later", "now", "soon", "again", "today", "tomorrow", "tonight", "yesterday", "more", "pls", "plz", "please",
        "up", "going", "gonna", "happening", "wrong", "new", "good", "next", "so", "the", "for", "with", "in", "on",
        "at", "to", "of", "and", "but", "or", "is", "are", "was", "no", "not", "doing", "else", "time",
    ]

    /// Stop words a topic may hold between its first and last word: "theory of relativity", "supply and demand".
    static let joinWords: Set<String> = ["the", "of", "and", "in", "on", "at", "to", "for", "with", "or", "is", "are", "was"]

    /// What the last sentence asks to explain, or nil for plain chat.
    static func detect(_ text: String) -> Ask? {
        let sentence = SmartDetect.lastSentence(text)
        guard !sentence.isEmpty, sentence.count <= maxQuestion else { return nil }
        let s = core(sentence)
        guard !s.isEmpty else { return nil }
        let question = sentence

        // Terms: the strong forms always name a term.
        for pattern in [
            #"^what (?:does|do|is|'s|s) (.+?) (?:mean|stand for)$"#,
            #"^what(?:'s| is|s) the meaning of (.+)$"#,
            #"^(?:the )?meaning of (.+)$"#,
            #"^wdym(?: by)? (.+)$"#,
            #"^define (.+)$"#,
        ] {
            if let x = capture(pattern, s) { return subject(x, maxWords: 4).map { Ask(kind: .term, subject: $0, question: question) } }
        }
        // "btw meaning": weak, so the server hears it only for one slang-like word.
        if let x = capture(#"^(.+?) meaning$"#, s), let t = subject(x, maxWords: 2) {
            return Ask(kind: .term, subject: t, question: question, askServerOnMiss: !t.contains(" "))
        }
        // Topics: "explain the water cycle", "eli5 how vaccines work", "explain why the sky is blue".
        for pattern in [
            #"^(?:eli5|explain like i'?m (?:5|five))[:,]? (.+)$"#,
            #"^explain(?: to me)?[:,]? (.+?)(?: to me)?$"#,
        ] {
            if let x = capture(pattern, s) {
                return howOrWhy(x, question: question, needsDoes: false)
                    ?? subject(x, maxWords: 6, topic: true).map { Ask(kind: .topic, subject: $0, question: question) }
            }
        }
        if let a = howOrWhy(s, question: question, needsDoes: true) { return a }
        // "what's btw" is a term when the dictionary knows it; "what is a log function" is a topic.
        if let x = capture(#"^what(?:'s| is|s) (?:(an?) )?(.+)$"#, s, group: 2), let t = subject(x, maxWords: 5) {
            if ExplainDictionary.shared.lookup(t) != nil { return Ask(kind: .term, subject: t, question: question) }
            return Ask(kind: .topic, subject: t, question: question)
        }
        return nil
    }

    /// The sentence lowercased, without the lead-in ("hey pip, can you") and the end marks.
    static func core(_ sentence: String) -> String {
        var s = sentence.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        s = s.replacingOccurrences(of: #"[\s?!.\x{2026}]+$"#, with: "", options: .regularExpression)
        let lead = #"^(?:(?:hey|hi|yo|ok|okay|so|wait|lol|haha|hmm+|um+|uh+|bro|dude|pip|pls|plz|please|sorry|but|and|also|quick q|q)\b[,:\s]*)+"#
        s = s.replacingOccurrences(of: lead, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"^(?:(?:can|could|would) (?:you|u) (?:please |pls )?|do (?:you|u) know |i wonder |anyone know )"#, with: "", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// "how does X work" asks about X; "explain why the sky is blue" asks the whole question. Bare "how X works" and any "why" only after "explain".
    private static func howOrWhy(_ s: String, question: String, needsDoes: Bool) -> Ask? {
        if let x = capture(needsDoes ? #"^how (?:does|do) (.+) work$"# : #"^how (?:(?:does|do) )?(.+?) works?$"#, s) {
            return subject(x, maxWords: 6, topic: true).map { Ask(kind: .topic, subject: $0, question: question) }
        }
        // A bare "why is the bus late" is everyday chat, not a question about a term. Only "explain why ..." asks.
        guard !needsDoes else { return nil }
        if let x = capture(#"^why (?:(?:is|are|do|does) )?(.+)$"#, s), subject(x, maxWords: 6, topic: true) != nil {
            return Ask(kind: .topic, subject: s, question: question)
        }
        return nil
    }

    /// The words to explain, cleaned, or nil when they are chat ("it", "later", "your mom").
    /// A topic drops a leading "the" and may hold a join word inside ("the theory of relativity").
    static func subject(_ raw: String, maxWords: Int, topic: Bool = false) -> String? {
        var t = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \"'\u{201C}\u{201D}`*"))
        let lead = topic ? #"^(?:the (?:word|term|phrase|slang|acronym) |an? |the )"# : #"^(?:the (?:word|term|phrase|slang|acronym) |an? )"#
        t = t.replacingOccurrences(of: lead, with: "", options: .regularExpression)
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: " \"'\u{201C}\u{201D}`*"))
        let words = t.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty, words.count <= maxWords, t.count <= 60 else { return nil }
        // A known phrase may hold a stop word ("no cap"); a lone stop word never counts ("what does it mean").
        if words.count > 1, ExplainDictionary.shared.lookup(t) != nil { return t }
        for (i, w) in words.enumerated() where stopWords.contains(w) {
            guard topic, i > 0, i < words.count - 1, joinWords.contains(w) else { return nil }
        }
        return t
    }

    private static func capture(_ pattern: String, _ s: String, group: Int = 1) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let r = Range(m.range(at: group), in: s) else { return nil }
        return String(s[r])
    }
}

/// A dictionary entry: what the term means and how people use it.
struct Meaning: Equatable {
    let term: String
    let meaning: String
    let example: String
}

/// The bundled explain-dictionary.json: chat abbreviations, slang and common terms, written for Pip. Loaded once, on first use.
final class ExplainDictionary {
    static let shared = ExplainDictionary()
    private let entries: [String: [String]]

    init(entries: [String: [String]]? = nil, bundle: Bundle = .main) {
        if let entries {
            self.entries = entries
        } else if let url = bundle.url(forResource: "explain-dictionary", withExtension: "json"),
                  let data = try? Data(contentsOf: url),
                  let e = try? JSONDecoder().decode([String: [String]].self, from: data) {
            self.entries = e
        } else {
            self.entries = [:]
        }
    }

    var count: Int { entries.count }

    /// Exact first, then with dots and apostrophes taken out ("e.g" finds "e.g.", "ur" stays "ur").
    func lookup(_ term: String) -> Meaning? {
        let key = term.lowercased().trimmingCharacters(in: .whitespaces)
        for k in [key, key + ".", key.replacingOccurrences(of: ".", with: ""), key.replacingOccurrences(of: "'", with: "")] {
            if let e = entries[k], e.count == 2 { return Meaning(term: key, meaning: e[0], example: e[1]) }
        }
        return nil
    }
}
