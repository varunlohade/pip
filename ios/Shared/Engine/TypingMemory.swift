import Foundation

/// The lines typed in this conversation, in memory only: never written to disk, cleared when the keyboard closes or the
/// field changes, at most 20 lines. The router gets the last 3 as context. A line with a secret is never kept.
struct TypingMemory: Equatable {
    static let cap = 20
    private(set) var lines: [String] = []

    mutating func add(_ line: String) {
        let l = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !l.isEmpty, l.count <= Explain.maxQuestion, !SecretFilter.isSecret(l), lines.last != l else { return }
        lines.append(l)
        if lines.count > Self.cap { lines.removeFirst(lines.count - Self.cap) }
    }

    mutating func clear() { lines = [] }

    /// The last `n` lines, oldest first, for the router.
    func context(_ n: Int = 3) -> [String] { Array(lines.suffix(n)) }
}
