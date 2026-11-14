import Foundation

/// Words that autocorrect and the Fix check never change: token symbols, chain names and crypto terms ("usdt" is never "used"),
/// ALL-CAPS words, words with digits, addresses and $-amounts.
enum CryptoWords {
    /// The pinned token symbols (server/src/pay/xchain/pins.ts), the chain ids and names (assets.ts), and common crypto words.
    static let all: Set<String> = [
        "aave", "ada", "arb", "avax", "bch", "bnb", "btc", "dai", "doge", "eth", "link", "ltc", "near", "op", "pepe", "pol",
        "shib", "sol", "sui", "trx", "uni", "usdc", "usdt", "wbtc", "wnear", "xrp",
        "base", "bsc", "gnosis", "tron", "ton", "cardano", "solana", "ethereum", "arbitrum", "optimism", "polygon", "avalanche",
        "bitcoin", "litecoin", "dogecoin", "matic", "testnet", "mainnet", "devnet",
        "usd1", "pyusd", "fdusd", "usde", "usds", "weth", "steth", "stablecoin", "stablecoins", "defi", "nft", "nfts", "dao",
        "dex", "cex", "gwei", "sats", "hodl", "airdrop", "memecoin", "onchain", "offchain", "metamask", "phantom", "web3",
        "crypto", "blockchain", "staking", "unstake", "bridge", "swap", "wallet", "gm", "wagmi", "ngmi", "fomo", "lfg",
    ]

    /// True for a word autocorrect and Fix must leave exactly as typed.
    static func keep(_ word: String) -> Bool {
        let w = word.trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:\"'()"))
        guard !w.isEmpty else { return false }
        if all.contains(w.lowercased()) { return true }
        if w.count >= 2, w.count <= 6, w.allSatisfy({ $0.isUppercase && $0.isLetter }) { return true }
        if w.contains(where: \.isNumber) || w.hasPrefix("$") { return true }
        return isAddress(w)
    }

    /// 0x…, bech32 (bc1…), base58 of 25+ characters, and .near / .testnet / .tg / .eth names.
    static func isAddress(_ w: String) -> Bool {
        let lower = w.lowercased()
        if lower.hasSuffix(".near") || lower.hasSuffix(".testnet") || lower.hasSuffix(".tg") || lower.hasSuffix(".eth") { return true }
        if lower.range(of: #"^0x[0-9a-f]{6,}$"#, options: .regularExpression) != nil { return true }
        // A NEAR implicit account. Outside a payment the secret filter calls the same 64 hex a private key first.
        if lower.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil { return true }
        if lower.range(of: #"^bc1[02-9ac-hj-np-z]{8,}$"#, options: .regularExpression) != nil { return true }
        return w.range(of: #"^[1-9A-HJ-NP-Za-km-z]{25,}$"#, options: .regularExpression) != nil && w.contains(where: \.isNumber)
    }

    /// Lines for the touch decoder's word list ("word<TAB>f"), so the slots know these words too.
    static var languageLines: String { all.sorted().map { "\($0)\t150" }.joined(separator: "\n") }
}
