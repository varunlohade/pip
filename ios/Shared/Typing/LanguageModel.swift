import Foundation

/// English words with their frequencies, and a letter 4-gram model built from them, for the touch decoder.
///
/// Data: `en-words.txt` (built by tools/build_words.py from AOSP LatinIME's en_US word list, Apache License 2.0).
/// The letter model is counted from the word list when it loads, so the bundle carries one small text file.
/// Self-contained: Foundation only. Pure after init, so it is safe to share across threads.
final class LanguageModel: @unchecked Sendable {
    /// a-z and the apostrophe. Index 27 is the start of a word, used only as context.
    static let letters: [Character] = Array("abcdefghijklmnopqrstuvwxyz'")
    private static let size = 28, start = 27, next = 27

    /// ln(probability) of each word, from AOSP's 0-255 log scale.
    let logFreq: [String: Float]
    /// The words in order, for prefix search.
    let sorted: [String]

    private let counts: [[Float]]
    private let totals: [[Float]]
    /// How strongly a short context backs off to a shorter one (Dirichlet smoothing).
    private let smoothing: Float = 4

    /// `text`: lines of "word<TAB>f"; lines starting with # are skipped.
    /// One pass over the bytes: each word is counted as it is read, so no copy of the lines is held.
    init(text: String) {
        var freq: [String: Float] = [:]
        freq.reserveCapacity(60_000)
        let n = Self.size, k = Self.next
        var counts = [n * n * n * k, n * n * k, n * k, k].map { [Float](repeating: 0, count: $0) }
        var totals = [n * n * n, n * n, n, 1].map { [Float](repeating: 0, count: $0) }
        let bytes = text.utf8
        var start = bytes.startIndex
        while start < bytes.endIndex {
            // A line ends at "\n", but not at the "\n" of "\r\n": that pair is one Character, as in split(separator: "\n").
            var end = start
            while end < bytes.endIndex, !(bytes[end] == 10 && (end == start || bytes[bytes.index(before: end)] != 13)) {
                end = bytes.index(after: end)
            }
            let line = text[start..<end]
            start = end < bytes.endIndex ? bytes.index(after: end) : end
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.utf8.split(separator: 9)
            guard parts.count == 2, let f = Float(Substring(parts[1])) else { continue }
            let w = String(Substring(parts[0]))
            freq[w] = (f - 255) / 8.59 * Float(M_LN2)
            // Half the log slope: common words count more, but "the" does not drown the rest.
            let weight = 1 + pow(2, (f - 100) / 17.18)
            var h = [Self.start, Self.start, Self.start]
            for ch in w {
                guard let c = Self.index(ch) else { break }
                Self.add(&counts, &totals, h, c, weight)
                h = [h[1], h[2], c]
            }
        }
        logFreq = freq
        sorted = freq.keys.sorted()
        self.counts = counts
        self.totals = totals
    }

    /// The bundled English model, or nil when the data file is missing.
    static func bundled(_ bundle: Bundle = .main) -> LanguageModel? {
        guard let url = bundle.url(forResource: "en-words", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return LanguageModel(text: text)
    }

    static func index(_ ch: Character) -> Int? {
        switch ch {
        case "a"..."z": return Int(ch.asciiValue! - 97)
        case "'", "\u{2019}": return 26
        default: return nil
        }
    }

    func contains(_ word: String) -> Bool { logFreq[word] != nil }

    /// Some word starts with `prefix`.
    func hasPrefix(_ prefix: String) -> Bool {
        var lo = 0, hi = sorted.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if sorted[mid] < prefix { lo = mid + 1 } else { hi = mid }
        }
        return lo < sorted.count && sorted[lo].hasPrefix(prefix)
    }

    /// The commonest words that start with `prefix` and are longer than it, commonest first.
    func completions(_ prefix: String, limit: Int) -> [String] {
        var lo = 0, hi = sorted.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if sorted[mid] < prefix { lo = mid + 1 } else { hi = mid }
        }
        var best: [(String, Float)] = []
        var i = lo
        while i < sorted.count, sorted[i].hasPrefix(prefix) {
            let w = sorted[i], f = logFreq[w]!
            i += 1
            guard w.count > prefix.count else { continue }
            if best.count < limit || f > best[best.count - 1].1 {
                best.append((w, f))
                best.sort { $0.1 > $1.1 }
                if best.count > limit { best.removeLast() }
            }
        }
        return best.map(\.0)
    }

    /// ln P(letter | the letters of the word so far). `word` is the current word up to the cursor, lowercased.
    func logP(_ letter: Character, after word: String) -> Double {
        guard let c = Self.index(letter) else { return log(1e-4) }
        var h = [Self.start, Self.start, Self.start]
        for ch in word.suffix(3) {
            guard let i = Self.index(ch) else { h = [Self.start, Self.start, Self.start]; continue }
            h = [h[1], h[2], i]
        }
        // Back off from the 3-letter context to none, smoothing each order with the one below.
        let n = Self.size, k = Self.next
        var p = 1 / Float(k)
        let ctx = [h[0] * n * n + h[1] * n + h[2], h[1] * n + h[2], h[2], 0]
        for order in (0..<4).reversed() {
            let t = totals[order][ctx[order]]
            p = (counts[order][ctx[order] * k + c] + smoothing * p) / (t + smoothing)
        }
        return Double(log(p))
    }

    private static func add(_ counts: inout [[Float]], _ totals: inout [[Float]], _ h: [Int], _ c: Int, _ w: Float) {
        let n = size, k = next
        let ctx = [h[0] * n * n + h[1] * n + h[2], h[1] * n + h[2], h[2], 0]
        for order in 0..<4 {
            counts[order][ctx[order] * k + c] += w
            totals[order][ctx[order]] += w
        }
    }
}
