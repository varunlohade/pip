import CoreGraphics
import Foundation

/// A letter key as the decoder sees it: its letter, where it is drawn, and its row (0 = top).
struct TouchKey: Equatable {
    let letter: Character
    let frame: CGRect
    let row: Int
}

/// Invisible key resizing, the way phone keyboards do it (AOSP LatinIME's ProximityInfo is the open-source take).
///
/// A tap scores every nearby letter as P(point | key) x P(letter | the letters before):
/// a 2D Gaussian around each key's centre, set a little low since thumbs land low, times a letter 4-gram.
/// The best letter goes in. A tap well inside a key (its inner 60%) always gives that key, so only edges move.
/// Keys never change on screen. Self-contained: Foundation and CoreGraphics only.
enum TouchDecoder {
    static let sigmaX: CGFloat = 0.45
    static let sigmaY: CGFloat = 0.35
    /// Where thumbs land, below the key's centre, as a share of key height.
    static let lowBias: CGFloat = 0.12
    /// The middle share of a key that always gives that key.
    static let core: CGFloat = 0.6
    /// How far from the touch a key may be and still be scored, in key widths.
    static let reach: CGFloat = 1.6
    /// sigmaY and lmWeight are tuned on TouchDecoderTests' harness: rows sit close, so a row jump must be clearer than a column one.
    static let lmWeight = 0.5

    struct Candidate: Equatable {
        let letter: Character
        /// The touch alone: how likely the finger meant this key, among the nearby ones.
        let probability: Double
    }

    struct Result: Equatable {
        let key: TouchKey
        /// The three likeliest keys by touch alone, likeliest first, for the word decoder.
        let candidates: [Candidate]
    }

    /// `word`: the current word before the cursor, lowercased. Nil `model` scores the touch alone.
    static func decode(_ p: CGPoint, keys: [TouchKey], word: String, model: LanguageModel?,
                       adaptation: TouchAdaptation = TouchAdaptation()) -> Result? {
        guard let nearest = keys.min(by: { distance(p, $0.frame) < distance(p, $1.frame) }) else { return nil }
        let w = nearest.frame.width, h = nearest.frame.height
        var scored: [(key: TouchKey, touch: Double, total: Double)] = []
        for key in keys {
            let mean = expected(key, adaptation)
            guard abs(mean.x - p.x) <= reach * w, abs(mean.y - p.y) <= reach * h else { continue }
            let dx = (p.x - mean.x) / (sigmaX * key.frame.width), dy = (p.y - mean.y) / (sigmaY * key.frame.height)
            let touch = Double(-0.5 * (dx * dx + dy * dy))
            let lm = model.map { lmWeight * $0.logP(key.letter, after: word) } ?? 0
            scored.append((key, touch, touch + lm))
        }
        guard !scored.isEmpty else { return Result(key: nearest, candidates: [Candidate(letter: nearest.letter, probability: 1)]) }
        let top = scored.map(\.touch).max()!
        let sum = scored.reduce(0) { $0 + exp($1.touch - top) }
        let candidates = scored.sorted { $0.touch > $1.touch }.prefix(3).map { Candidate(letter: $0.key.letter, probability: exp($0.touch - top) / sum) }
        let inCore = nearest.frame.insetBy(dx: w * (1 - core) / 2, dy: h * (1 - core) / 2).contains(p)
        let best = inCore ? nearest : scored.max { $0.total < $1.total }!.key
        return Result(key: best, candidates: candidates)
    }

    /// Where a finger aiming at `key` lands on average: a little low, plus what this person's taps taught.
    static func expected(_ key: TouchKey, _ adaptation: TouchAdaptation) -> CGPoint {
        let o = adaptation.offset(row: key.row)
        return CGPoint(x: key.frame.midX + o.dx * key.frame.width, y: key.frame.midY + (lowBias + o.dy) * key.frame.height)
    }

    private static func distance(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX), dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return dx * dx + dy * dy
    }

    // MARK: word decode

    /// A tap that never registered costs less than one on a far key; an extra tap sits between.
    static let missedTapCost = 4.5
    static let extraTapCost = 5.0
    static let swapCost = 4.0
    /// The least score (touch vs typed, plus ln word frequency) a fix needs: a common word one missed tap away,
    /// or a rarer one the taps point at. A rare word one blind edit away (a name: "arpit" to "armpit") stays as typed.
    static let minScore = -16.0
    /// A letter the touch never offered costs as if it had this probability. Pip: lower than Muninn's 0.0025, so a far
    /// key does not beat a missed tap on a chat word ("helo" is "hello", not "held").
    static let unseenProbability = 0.0005

    /// On space: the word the taps most likely meant, when what they typed is not a word. Nil keeps the typed word.
    /// Scores each candidate by touch likelihood x word frequency: a beam over each tap's top keys, plus one edit.
    /// `taps`: each tap's candidates, one per letter of `typed`, or nil when unknown (pasted, VoiceOver).
    static func correctWord(_ typed: String, taps: [[Candidate]]?, model: LanguageModel) -> String? {
        let letters = Array(typed)
        guard letters.count >= 2, letters.count <= 24, !model.contains(typed),
              letters.allSatisfy({ LanguageModel.index($0) != nil }) else { return nil }
        let taps = taps?.count == letters.count ? taps : nil
        func touchLog(_ i: Int, _ c: Character) -> Double {
            guard let t = taps?[i] else { return c == letters[i] ? 0 : log(unseenProbability) }
            return log(t.first { $0.letter == c }?.probability ?? unseenProbability)
        }
        let typedScore = letters.indices.reduce(0) { $0 + touchLog($1, letters[$1]) }
        var best: (word: String, score: Double)?
        func consider(_ word: String, _ touch: Double) {
            guard let f = model.logFreq[word] else { return }
            let s = touch - typedScore + Double(f)
            if best == nil || s > best!.score { best = (word, s) }
        }
        // Beam over the keys each tap could have meant.
        if let taps {
            var beam: [(String, Double)] = [("", 0)]
            for (i, t) in taps.enumerated() {
                var grown: [(String, Double)] = []
                for (prefix, s) in beam {
                    for c in t {
                        let next = prefix + String(c.letter)
                        if model.hasPrefix(next) { grown.append((next, s + log(c.probability))) }
                    }
                    if !t.contains(where: { $0.letter == letters[i] }), model.hasPrefix(prefix + String(letters[i])) {
                        grown.append((prefix + String(letters[i]), s + touchLog(i, letters[i])))
                    }
                }
                beam = Array(grown.sorted { $0.1 > $1.1 }.prefix(32))
            }
            for (w, s) in beam { consider(w, s) }
        }
        // One edit: a letter swapped for another, dropped, added, or two letters crossed.
        let alphabet = LanguageModel.letters
        for i in letters.indices {
            let base = typedScore - touchLog(i, letters[i])
            for c in alphabet where c != letters[i] {
                var w = letters; w[i] = c
                consider(String(w), base + touchLog(i, c))
            }
            var dropped = letters; dropped.remove(at: i)
            consider(String(dropped), base - extraTapCost)
            if i + 1 < letters.count {
                var crossed = letters; crossed.swapAt(i, i + 1)
                consider(String(crossed), typedScore - swapCost)
            }
        }
        for i in 0...letters.count {
            for c in alphabet {
                var w = letters; w.insert(c, at: i)
                consider(String(w), typedScore - missedTapCost)
            }
        }
        return best.flatMap { $0.score >= minScore ? $0.word : nil }
    }
}

/// What one person's taps teach: how far from the expected point they land, per row, as a share of key size.
/// A running mean of taps that were not deleted right after, clamped so a few odd taps cannot move the keys far.
struct TouchAdaptation: Equatable {
    static let rows = 3
    static let rate = 0.05
    static let maxX = 0.2
    static let maxY = 0.25
    private(set) var dx: [CGFloat] = Array(repeating: 0, count: rows)
    private(set) var dy: [CGFloat] = Array(repeating: 0, count: rows)

    init() {}

    /// From `values` as `stored` wrote them; anything else starts fresh.
    init(stored values: [Double]) {
        guard values.count == 2 * Self.rows else { return }
        dx = values.prefix(Self.rows).map { Self.clamp(CGFloat($0), Self.maxX) }
        dy = values.suffix(Self.rows).map { Self.clamp(CGFloat($0), Self.maxY) }
    }

    var stored: [Double] { (dx + dy).map(Double.init) }

    func offset(row: Int) -> (dx: CGFloat, dy: CGFloat) {
        guard dx.indices.contains(row) else { return (0, 0) }
        return (dx[row], dy[row])
    }

    /// One kept tap on `key` at `point`.
    mutating func learn(_ point: CGPoint, on key: TouchKey) {
        guard dx.indices.contains(key.row) else { return }
        let sx = (point.x - key.frame.midX) / key.frame.width
        let sy = (point.y - key.frame.midY) / key.frame.height - TouchDecoder.lowBias
        let r = key.row, a = CGFloat(Self.rate)
        dx[r] = Self.clamp(dx[r] + a * (sx - dx[r]), Self.maxX)
        dy[r] = Self.clamp(dy[r] + a * (sy - dy[r]), Self.maxY)
    }

    private static func clamp(_ v: CGFloat, _ m: Double) -> CGFloat { min(max(v, -CGFloat(m)), CGFloat(m)) }
}
