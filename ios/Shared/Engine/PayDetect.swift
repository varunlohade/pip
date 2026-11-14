import Foundation

/// "send 5 USDC to ana.testnet" read on the phone. Only this one shape, so nothing is guessed. The server checks it again.
struct PayDraft: Equatable, Hashable {
    let amount: String
    /// "NEAR" or "USDC".
    let token: String
    /// The account as this build sends it (PayNetwork.account): on testnet, "ana.near" is read as "ana.testnet".
    let recipient: String
    /// The words that made the chip, as typed.
    let trigger: String

    var label: String { "Send \(amount) \(token) to \(recipient)" }
}

enum PayDetect {
    private static let re = try! NSRegularExpression(
        pattern: #"\b(?:send|pay|transfer|give)\s+(\$\s?)?(\d{1,12}(?:\.\d{1,24})?)\s*(near|usdc)\s+to\s+@?([a-z0-9_-]+(?:\.[a-z0-9_-]+)*\.(?:testnet|near))(?=$|[\s,;!?]|\.(?:\s|$))"#,
        options: [.caseInsensitive])

    /// The last payment in the text, or nil.
    static func detect(_ text: String) -> PayDraft? {
        let ns = text as NSString
        guard let m = re.matches(in: text, range: NSRange(location: 0, length: ns.length)).last else { return nil }
        let amount = ns.substring(with: m.range(at: 2))
        guard Double(amount).map({ $0 > 0 }) == true else { return nil }
        let token = ns.substring(with: m.range(at: 3)).uppercased()
        // "$" is only a unit for a dollar coin: "$5 USDC" is 5 USDC; "$5 NEAR" is unclear, so no chip.
        if m.range(at: 1).location != NSNotFound, token != "USDC" || !Flags.dollarPay { return nil }
        if token == "USDC", let dot = amount.firstIndex(of: "."), amount[amount.index(after: dot)...].count > 6 { return nil }
        let id = PayNetwork.account(ns.substring(with: m.range(at: 4)).lowercased())
        guard id.count <= 64 else { return nil }
        return PayDraft(amount: amount, token: token, recipient: id, trigger: ns.substring(with: m.range))
    }

    /// What the bar says to "send 1 near to ana.mainnet": mainnet is a network, not an account ending.
    static let suffixHelp = "NEAR accounts end in .near (mainnet) or .testnet"

    private static let mainnetRe = try! NSRegularExpression(
        pattern: #"\b(?:send|pay|transfer|give)\s+\$?\s?\d{1,12}(?:\.\d{1,24})?\s*(?:near|usdc)\s+to\s+@?[a-z0-9_-]+(?:\.[a-z0-9_-]+)*\.mainnet(?=$|[\s,;!?.])"#,
        options: [.caseInsensitive])

    /// The words of a payment to a ".mainnet" account, or nil.
    static func mainnetSuffix(_ text: String) -> String? {
        let ns = text as NSString
        return mainnetRe.matches(in: text, range: NSRange(location: 0, length: ns.length)).last.map { ns.substring(with: $0.range) }
    }
}
