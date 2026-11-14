import Foundation

/// The gate before any typed text leaves the phone. A line with a secret never goes to the router, the explain or pay
/// servers, and is not kept in the typing memory. It never changes what is typed or sent.
enum SecretFilter {
    enum Hit: Equatable { case cardNumber, code, token, privateKey, seedPhrase, password }

    /// What makes `line` secret, or nil when it may go to the server.
    static func scan(_ line: String) -> Hit? {
        if SecretScan.hasCardNumber(line) { return .cardNumber }
        let words = line.split(whereSeparator: \.isWhitespace).map { trim(String($0)) }.filter { !$0.isEmpty }
        if words.contains(where: { $0.count == 6 && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }) { return .code }
        if line.contains("PRIVATE KEY-----") { return .privateKey }
        let paying = isPayment(line)
        // "send 0.02 near to <recipient>": the word after the last "to" is who gets paid, not a password or a token.
        let recipient = paying ? words.lastIndex { $0.lowercased() == "to" }.map { $0 + 1 } : nil
        for (i, w) in words.enumerated() {
            if isPrivateKey(w, paying: paying) { return .privateKey }
            // A wallet address a payment needs is not a secret, though it looks like a long token.
            if CryptoWords.isAddress(w) || i == recipient { continue }
            if SecretScan.looksLikeToken(w) || isToken(w) { return .token }
            if isPassword(w) { return .password }
        }
        if hasSeedPhrase(words) { return .seedPhrase }
        return nil
    }

    static func isSecret(_ line: String) -> Bool { scan(line) != nil }

    /// The line without the word still being typed: everything up to the last space.
    static func finishedWords(_ line: String) -> String {
        String(line[..<(line.lastIndex(where: \.isWhitespace) ?? line.startIndex)])
    }

    /// "send 5 USDC to <64 hex>": a NEAR implicit account the pay flow needs, not a key.
    private static func isPayment(_ line: String) -> Bool {
        line.range(of: #"\b(?:send|pay|transfer|give|bridge|bhej\w*)\b.*\bto\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static let base58 = #"[1-9A-HJ-NP-Za-km-z]"#

    /// 64 hex with 0x (an EVM key), or without it outside a payment; ed25519:/secp256k1: keys; WIF; long base58 (Solana secret keys).
    static func isPrivateKey(_ w: String, paying: Bool = false) -> Bool {
        if w.range(of: #"^0x[0-9a-fA-F]{64}$"#, options: .regularExpression) != nil { return true }
        if !paying, w.range(of: #"^[0-9a-fA-F]{64}$"#, options: .regularExpression) != nil { return true }
        if w.range(of: #"^(?:ed25519|secp256k1):\#(base58){80,}$"#, options: .regularExpression) != nil { return true }
        if w.range(of: #"^[5KL]\#(base58){50,51}$"#, options: .regularExpression) != nil { return true }
        return w.range(of: #"^\#(base58){80,}$"#, options: .regularExpression) != nil
    }

    /// API keys by their prefix (sk_, pk_, api_, ghp_, xox…), on top of SecretScan's list.
    static func isToken(_ w: String) -> Bool {
        guard w.count >= 16 else { return false }
        return ["sk_", "pk_", "api_", "ghp_", "xox", "sk-", "rk_"].contains { w.lowercased().hasPrefix($0) }
    }

    /// One word that mixes three of upper, lower, digit and symbol, at least 8 long, and is not a word with a number
    /// ("iPhone15", "COVID-19"), an amount, an email, a link or an address. The account marks . - _ are not symbols,
    /// so "pipfund42.mainnet" is lower and digit only.
    static func isPassword(_ w: String) -> Bool {
        guard w.count >= 8, w.count <= 64 else { return false }
        if w.hasPrefix("$") || w.hasPrefix("@") || w.hasPrefix("#") || w.contains("://") || w.lowercased().hasPrefix("www.") { return false }
        if w.range(of: #"^[^@\s]+@[^@\s]+\.[a-z]{2,}$"#, options: [.regularExpression, .caseInsensitive]) != nil { return false }
        if CryptoWords.isAddress(w) { return false }
        // A word and a number: "iPhone15", "COVID-19", "Windows11", "MacBookPro16", "Q4-2025".
        if w.range(of: #"^[A-Za-z]+[-_ ]?\d{1,4}(?:[-/]\d{1,4})?$"#, options: .regularExpression) != nil { return false }
        if w.range(of: #"^\d{1,4}[A-Za-z]{1,4}$"#, options: .regularExpression) != nil { return false }
        // Dates, times, sums and plain numbers: digits with : / . , - x % only.
        if w.range(of: #"^[\d:/.,\-x%+*=()]+(?:am|pm|AM|PM)?$"#, options: .regularExpression) != nil { return false }
        // Words joined by hyphens or apostrophes: "Well-known", "Couldn't", "Mother-in-law".
        if w.range(of: #"^[A-Za-z]+(?:['\u{2019}-][A-Za-z]+)+$"#, options: .regularExpression) != nil { return false }
        var classes = 0
        if w.contains(where: \.isUppercase) { classes += 1 }
        if w.contains(where: \.isLowercase) { classes += 1 }
        if w.contains(where: \.isNumber) { classes += 1 }
        if w.contains(where: { !$0.isLetter && !$0.isNumber && !".-_".contains($0) }) { classes += 1 }
        return classes >= 3
    }

    /// 12 or more words in a row that are all in the BIP39 English list.
    static func hasSeedPhrase(_ words: [String]) -> Bool {
        guard words.count >= 12 else { return false }
        var run = 0
        for w in words {
            run = bip39.contains(w.lowercased()) ? run + 1 : 0
            if run >= 12 { return true }
        }
        return false
    }

    /// The word without the sentence marks and quotes around it.
    private static func trim(_ w: String) -> String {
        var s = Substring(w)
        while let f = s.first, "\"'(\u{201C}\u{2018}[".contains(f) { s = s.dropFirst() }
        while let l = s.last, ".,!?;:\"')\u{201D}\u{2019}]".contains(l) { s = s.dropLast() }
        return String(s)
    }

    /// The 2048 BIP39 English words, bundled as bip39-english.txt. Loaded once.
    static let bip39: Set<String> = {
        let bundles = [Bundle.main, Bundle(for: BundleToken.self)]
        for b in bundles {
            if let url = b.url(forResource: "bip39-english", withExtension: "txt"), let text = try? String(contentsOf: url, encoding: .utf8) {
                return Set(text.split(whereSeparator: \.isNewline).map(String.init))
            }
        }
        return []
    }()
    private final class BundleToken {}
}
