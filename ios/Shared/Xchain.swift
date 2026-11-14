import CryptoKit
import Foundation

// Cross-chain pay (NEAR Intents 1Click, mainnet only). The server parses, quotes and checks every number; the phone shows
// its display strings as they are and checks the deposit transaction against the card before Face ID.

/// One amount as the server wrote it. `text` is shown as is; `units` is what the transaction must carry.
struct XchainAmount: Decodable, Equatable {
    let units: String
    let text: String
    let symbol: String
    let decimals: Int
}

/// The numbers of one checked quote.
struct XchainNumbers: Decodable, Equatable {
    struct Fee: Decodable, Equatable {
        let in_origin: XchainAmount
        var usd: String?
    }
    struct Rate: Decodable, Equatable { let text: String }
    var mode: String?
    let amount_out: XchainAmount
    var min_amount_out: XchainAmount?
    let max_amount_in: XchainAmount
    let fee: Fee
    let rate: Rate
    let eta_seconds: Int
}

/// The card for one cross-chain payment: GET /v1/pay/intents/:id `xchain`, the /quote answer, or the re-quote in /unsigned.
/// An answer that did not pass the server's checks has `verified` false and says why; it has no intent and cannot be approved.
struct XchainCard: Decodable, Equatable {
    struct Destination: Decodable, Equatable {
        let chain: String
        let chain_name: String
        let recipient: String
        /// Nil from an older server: treated as first time.
        var first_time: Bool?
    }
    var verified: Bool
    var notVerified: [String] = []
    var numbers: XchainNumbers?
    var destination: Destination?
    var deposit_address: String?
    var refund_to: String?
    /// A swap from the user's NEAR wallet to their own account or saved address.
    var swap = false
    /// A live dry quote with every check run, shown when Pip cannot send it (testnet, or too little in the wallet). Never approvable.
    var preview = false
    /// What a preview needs before it can send, in the server's words: "Need 0.8 more NEAR".
    var action: String?
    var slippageBps: Int?
    /// "NEAR in your NEAR wallet", "NEAR Intents solvers", "USDC on NEAR".
    var routePath: [String] = []

    enum CodingKeys: String, CodingKey {
        case verified, not_verified, numbers, destination, deposit_address, refund_to, error, swap, preview, action, slippage_bps, route_path
    }

    init(verified: Bool, notVerified: [String] = [], numbers: XchainNumbers?, destination: Destination?, deposit_address: String?, refund_to: String?) {
        self.verified = verified
        self.notVerified = notVerified
        self.numbers = numbers
        self.destination = destination
        self.deposit_address = deposit_address
        self.refund_to = refund_to
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        verified = try c.decodeIfPresent(Bool.self, forKey: .verified) ?? false
        notVerified = try c.decodeIfPresent([String].self, forKey: .not_verified) ?? []
        if let e = try c.decodeIfPresent(String.self, forKey: .error) { notVerified.append(e) }
        // A verified card carries its numbers at the top; an unverified answer nests them under `numbers`.
        numbers = try c.decodeIfPresent(XchainNumbers.self, forKey: .numbers) ?? (try? XchainNumbers(from: decoder))
        destination = try c.decodeIfPresent(Destination.self, forKey: .destination)
        deposit_address = try c.decodeIfPresent(String.self, forKey: .deposit_address)
        refund_to = try c.decodeIfPresent(String.self, forKey: .refund_to)
        swap = try c.decodeIfPresent(Bool.self, forKey: .swap) ?? false
        preview = try c.decodeIfPresent(Bool.self, forKey: .preview) ?? false
        action = try c.decodeIfPresent(String.self, forKey: .action)
        slippageBps = try c.decodeIfPresent(Int.self, forKey: .slippage_bps)
        routePath = try c.decodeIfPresent([String].self, forKey: .route_path) ?? []
    }

    /// Approve needs a verified card with numbers and a deposit account, and never a preview.
    var approvable: Bool { verified && !preview && numbers != nil && deposit_address != nil && destination != nil }
    var firstTime: Bool { destination?.first_time ?? true }
}

/// POST /v1/pay/xchain/quote: the card, and the intent to approve when the quote passed.
struct XchainQuote: Decodable, Equatable {
    let card: XchainCard
    var intent: PayIntent?

    enum CodingKeys: String, CodingKey { case intent }
    init(card: XchainCard, intent: PayIntent?) { self.card = card; self.intent = intent }
    init(from decoder: Decoder) throws {
        card = try XchainCard(from: decoder)
        intent = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(PayIntent.self, forKey: .intent)
    }
}

/// POST /v1/pay/xchain/parse. The server's reading is the one Pip uses; the phone's regex only decides when to ask.
struct XchainParsed: Decodable, Equatable, Hashable {
    let valid: Bool
    var kind: String?
    var amount: String?
    var token: String?
    var chain: String?
    var recipient: String?
    var from: String?
    var reason: String?
    /// "chain": an 0x address with no chain named. The bar asks which chain.
    var needs: String?
}

/// GET /v1/pay/xchain/:id.
struct XchainStatus: Decodable, Equatable {
    struct DestTx: Decodable, Equatable { let hash: String; let explorerUrl: String? }
    let status: String
    var delivered_tx: [DestTx]?
    var refund_reason: String?
}

/// The chip for a cross-chain ask, before the card.
enum XchainOffer: Equatable {
    /// The server read a payment: tap to get a checked quote.
    case ready(XchainParsed, trigger: String)
    /// Testnet: Intents has no testnet.
    case needsMainnet(trigger: String)
    /// The server did not read a payment it can make; its reason, in its words.
    case refused(String, trigger: String)
    /// An 0x address fits many chains: the bar offers one chip per chain, and a tap adds "on base" to the text.
    case whichChain(trigger: String)
    /// "swap 1 near to usdc": tap for a checked quote (a live preview when Pip cannot send it).
    case swap(XchainParsed, trigger: String)
    /// "request 5 usdc on base" or "top up my pip with 20 usdc from base": tap for a checked deposit address. Pip moves no money.
    case request(XchainParsed, trigger: String)
    /// A request with no chain: "Which chain will they pay from?" and one chip per chain.
    case chainChoice(prompt: String, chains: [ChainChoice], trigger: String)

    var trigger: String {
        switch self {
        case .ready(_, let t), .needsMainnet(let t), .refused(_, let t), .whichChain(let t), .swap(_, let t), .request(_, let t), .chainChoice(_, _, let t): t
        }
    }

    /// The EVM chains the "Which chain?" chips offer, as the words the server reads ("on arbitrum").
    static let evmChains: [(title: String, words: String)] = [
        ("Ethereum", "ethereum"), ("Base", "base"), ("Arbitrum", "arbitrum"), ("BNB", "bsc"), ("Polygon", "polygon"), ("OP", "optimism"),
    ]

    static let mainnetLine = "Cross-chain pay needs Mainnet. Switch in Pip Pay."
}

/// The keyboard's cheap test before it asks the server: a pay verb, an amount, a token word, "to", and something shaped like
/// an address on another chain (or a NEAR account paid in a token the plain flow does not send).
enum XchainDetect {
    private static let re = try! NSRegularExpression(
        pattern: #"\b(?:send|pay|transfer|give)\s+(\$\s?)?\d[\d.]*\s*(?:(?:bucks|dollars|usd)\s+(?:of|in|worth\s+of)\s+)?([a-z][a-z0-9]{1,9}\b)?[^\n]{0,40}?\bto\s+@?(0x[0-9a-f]{40}|bc1[a-z0-9]{20,90}|[13][1-9a-z]{25,34}|t[1-9a-z]{33}|r[1-9a-z]{24,34}|[1-9a-z]{32,44}|[a-z0-9_-]+(?:\.[a-z0-9_-]+)*\.near)\b[^\n]{0,60}"#,
        options: [.caseInsensitive])

    /// The words to send to /v1/pay/xchain/parse, or nil. A plain NEAR send (PayDetect) is never a cross-chain ask.
    static func candidate(_ text: String) -> String? {
        guard PayDetect.detect(text) == nil else { return nil }
        if let w = IntentsDetect.candidate(text) { return w }
        let ns = text as NSString
        guard let m = re.matches(in: text, range: NSRange(location: 0, length: ns.length)).last else { return nil }
        // "$5 to …" has no token: the server reads the $ as USDC. Without a $, a token is needed.
        let dollar = m.range(at: 1).location != NSNotFound
        if dollar, !Flags.dollarPay { return nil }
        guard m.range(at: 2).location != NSNotFound || dollar else { return nil }
        let token = m.range(at: 2).location != NSNotFound ? ns.substring(with: m.range(at: 2)).lowercased() : "usdc"
        let to = ns.substring(with: m.range(at: 3)).lowercased()
        if to.hasSuffix(".near"), ["near", "usdc"].contains(token), !dollar { return nil }
        return String(ns.substring(with: m.range).trimmingCharacters(in: .whitespaces).prefix(500))
    }
}

/// The card's lines, made from the server's display strings only. Nothing here parses an amount into a number.
struct XchainCardText: Equatable {
    let gets: String
    let pays: String
    let fee: String
    let rate: String
    let route: String
    let eta: String
    let refund: String
    /// "Slippage: up to 1%"
    let slippage: String
    let intents = "Routed by NEAR Intents solvers"
    /// "NEAR in your NEAR wallet → NEAR Intents solvers → USDC on NEAR"
    let path: String
    /// "Live NEAR Intents quote · preview" on a preview, else nil.
    let previewTag: String?
    /// Why Approve is off, or nil.
    let blocked: String?

    static let previewTitle = "Live NEAR Intents quote \u{00B7} preview"

    init(_ card: XchainCard) {
        let n = card.numbers, d = card.destination
        let who = d.map { Self.short($0.recipient) } ?? "The recipient"
        let chain = d?.chain_name ?? "the other chain"
        if let n {
            let verb = n.mode == "exact_in" ? "exactly" : "at most"
            if card.swap {
                // A swap lands with the owner: on NEAR in their own account, elsewhere at their saved address.
                let at = chain == "NEAR" ? "" : " on \(chain)"
                let out = n.min_amount_out ?? n.amount_out
                gets = "You get at least \(out.text) \(out.symbol)\(at)"
                pays = "You swap \(verb) \(n.max_amount_in.text) \(Self.origin(n.max_amount_in.symbol)) from your NEAR wallet"
            } else {
                if n.mode == "exact_in", let min = n.min_amount_out {
                    gets = "\(who) gets at least \(min.text) \(min.symbol) on \(chain)"
                } else {
                    gets = "\(who) gets exactly \(n.amount_out.text) \(n.amount_out.symbol) on \(chain)"
                }
                pays = "You pay \(verb) \(n.max_amount_in.text) \(Self.origin(n.max_amount_in.symbol)) from your NEAR wallet"
            }
            fee = "Fee \(n.fee.in_origin.text) \(Self.origin(n.fee.in_origin.symbol))" + (n.fee.usd.map { " ($\($0))" } ?? "")
            rate = n.rate.text
            eta = Self.eta(n.eta_seconds)
        } else {
            gets = "\(who) on \(chain)"
            pays = "No price yet"
            fee = ""
            rate = ""
            eta = ""
        }
        route = "via NEAR Intents"
        refund = "Refunds go to " + (card.refund_to.map { Self.short($0) } ?? "your NEAR wallet")
        slippage = "Slippage: up to " + Self.percent(card.slippageBps ?? 100)
        path = card.routePath.joined(separator: " \u{2192} ")
        previewTag = card.preview ? Self.previewTitle : nil
        if card.preview {
            blocked = card.verified ? (card.action ?? "Preview only. Nothing can be sent from here.")
                : "Pip could not check this price: " + (card.notVerified.isEmpty ? "no reason given" : card.notVerified.joined(separator: "; "))
        } else if !card.verified {
            blocked = "Pip could not check this price: " + (card.notVerified.isEmpty ? "no reason given" : card.notVerified.joined(separator: "; "))
        } else if !card.approvable {
            blocked = "This quote is missing details, so Pip will not send it."
        } else {
            blocked = nil
        }
    }

    /// "0xd8dA…9da3" for long addresses; short names such as "ana.near" stay whole.
    static func short(_ a: String) -> String {
        a.count <= 16 ? a : "\(a.prefix(6))\u{2026}\(a.suffix(4))"
    }

    /// 1Click names wrapped NEAR "wNEAR"; the owner holds NEAR.
    static func origin(_ symbol: String) -> String { symbol.uppercased() == "WNEAR" ? "NEAR" : symbol }

    /// Basis points as a percent, with integer math only: 100 -> "1%", 50 -> "0.5%", 125 -> "1.25%".
    static func percent(_ bps: Int) -> String {
        let whole = bps / 100, frac = bps % 100
        if frac == 0 { return "\(whole)%" }
        return frac % 10 == 0 ? "\(whole).\(frac / 10)%" : "\(whole).\(frac < 10 ? "0" : "")\(frac)%"
    }

    static func eta(_ s: Int) -> String {
        if s <= 0 { return "Time not given" }
        if s < 90 { return "About \(s) seconds" }
        return "About \((s + 59) / 60) minutes"
    }
}

/// Where a sent cross-chain payment is, from GET /v1/pay/xchain/:id.
enum SwapState: Equatable {
    case swapping
    case delivered(url: String?)
    case refunded(String?)
    case failed(String)

    init?(_ s: XchainStatus) {
        switch s.status {
        case "delivered": self = .delivered(url: s.delivered_tx?.first?.explorerUrl)
        case "refunded": self = .refunded(s.refund_reason)
        case "failed": self = .failed("The swap failed. NEAR Intents sends the money back to your NEAR wallet.")
        case "incomplete_deposit": self = .failed("NEAR Intents got less than it needed. It sends the money back to your NEAR wallet.")
        case "not_sent": self = .failed("It did not go through. Nothing left your wallet.")
        default: return nil
        }
    }

    var done: Bool { self != .swapping }

    func line(chain: String) -> String {
        switch self {
        case .swapping: return "Swapping\u{2026}"
        case .delivered: return "Sent on \(chain) \u{2713}"
        case .refunded(let why): return "Refunded. The money is back in your NEAR wallet." + (why.map { " (\($0))" } ?? "")
        case .failed(let s): return s
        }
    }
}

/// First time paying an address: the card shows the whole address with its ending marked, and the owner taps that ending
/// (one of three) before the PIN. A ".near"/".testnet" name ends at its last 4 characters before the suffix.
struct AddressConfirm: Equatable {
    let address: String
    let options: [String]
    var picked: String?

    /// Characters a decoy never uses, so no wrong option differs from the right one by a lookalike only.
    static let confusable: Set<Character> = ["0", "O", "o", "1", "l", "I", "i", "|"]

    /// The address in three parts: before the ending, the ending, and a name suffix such as ".testnet".
    var parts: (head: String, end: String, tail: String) { Self.split(address) }
    var answer: String { parts.end }
    var confirmed: Bool { picked == answer }

    static func split(_ a: String) -> (head: String, end: String, tail: String) {
        var base = Substring(a), tail = ""
        for s in [".testnet", ".near"] where a.count > s.count && a.lowercased().hasSuffix(s) {
            base = a.dropLast(s.count)
            tail = String(a.suffix(s.count))
            break
        }
        return (String(base.dropLast(4)), String(base.suffix(4)), tail)
    }

    init(_ address: String) {
        self.address = address
        let real = Self.split(address).end
        let chars = Array(real)
        let hex = chars.allSatisfy(\.isHexDigit)
        let upper = chars.contains { $0.isUppercase }, lower = chars.contains { $0.isLowercase }
        let letters = hex ? "abcdef" : "abcdefghjkmnpqrstuvwxyz"
        let cased = upper && !lower ? letters.uppercased() : upper ? letters + letters.uppercased() : letters
        let pool = Array("23456789" + cased).filter { !Self.confusable.contains($0) }
        // Each decoy differs from the real ending in at least 3 places (all places when it is shorter), case aside.
        let need = min(3, chars.count)
        var seed = address.unicodeScalars.reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1.value)) &* 1099511628211 }
        var decoys: [String] = []
        for _ in 0..<500 where decoys.count < 2 {
            var c: [Character] = []
            for _ in chars {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                c.append(pool[Int((seed >> 33) % UInt64(pool.count))])
            }
            let s = String(c)
            let diff = zip(c, chars).filter { $0.lowercased() != $1.lowercased() }.count
            if diff >= need, !decoys.contains(s) { decoys.append(s) }
        }
        var opts = decoys
        let slot = address.unicodeScalars.reduce(0) { ($0 + Int($1.value)) % 3 }
        opts.insert(real, at: slot)
        options = opts
    }
}

/// Approval helpers shared by the keyboard and the app.
enum PayApproval {
    /// What the keyboard signs to show the server that Face ID approved this exact intent (server: approvalMessage).
    static func proofHash(_ i: PayIntent) -> Data {
        Data(SHA256.hash(data: Data(["pip-approve/v1", i.id, i.network, i.amount, i.token, i.recipient].joined(separator: "\n").utf8)))
    }
}

extension APIClient {
    func parseXchain(_ text: String) async throws -> XchainParsed {
        try await send(request("POST", "/v1/pay/xchain/parse", body: ["text": text]), as: XchainParsed.self)
    }

    /// A checked quote, exact output by default. A swap is exact input to the owner's own account (POST /swap).
    /// A 422 refusal comes back as an unverified card with the server's reason. On testnet the server answers a live preview.
    func quoteXchain(_ p: XchainParsed) async throws -> XchainQuote {
        let swap = p.kind == "swap"
        var body = swap ? ["amount": p.amount ?? "", "token": p.token ?? "", "chain": p.chain ?? "near"]
            : ["amount": p.amount ?? "", "token": p.token ?? "", "chain": p.chain ?? "", "recipient": p.recipient ?? ""]
        if let f = p.from { body["from"] = f }
        do {
            return try await send(request("POST", swap ? "/v1/pay/xchain/swap" : "/v1/pay/xchain/quote", body: body, tap: true, timeout: 40),
                                  as: XchainQuote.self)
        } catch APIError.http(422, let raw) {
            let card = try JSONDecoder().decode(XchainCard.self, from: Data(raw.utf8))
            return XchainQuote(card: card, intent: nil)
        }
    }

    func xchainStatus(_ id: String) async throws -> XchainStatus {
        try await send(request("GET", "/v1/pay/xchain/\(id)", timeout: 20), as: XchainStatus.self)
    }
}

extension PayTxCheck {
    /// The NEP-141 contract each origin token is paid from on mainnet.
    static let originContracts = ["NEAR": "wrap.near", "USDC": usdcContracts["mainnet"]!, "USDT": "usdt.tether-token.near"]
    static let originDecimals = ["NEAR": 24, "USDC": 6, "USDT": 6]

    /// The 1Click deposit: every action goes to the origin token contract. [storage_deposit(signer), NEAR only]
    /// [storage_deposit(deposit account)] [near_deposit(exact max input), NEAR only] ft_transfer(deposit account, exact max input).
    static func checkXchain(_ tx: Tx, intent i: PayIntent, account: String, card: XchainCard) -> Result<Seen, Refusal> {
        guard card.approvable, let n = card.numbers, let deposit = card.deposit_address else { return .failure(.mismatch("card")) }
        guard i.network == "mainnet" else { return .failure(.mismatch("network")) }
        guard i.recipient == deposit else { return .failure(.mismatch("deposit address")) }
        guard let contract = originContracts[i.token], let decimals = originDecimals[i.token], n.max_amount_in.decimals == decimals else {
            return .failure(.mismatch("token"))
        }
        let max = n.max_amount_in.units
        guard units(i.amount, decimals: decimals) == max, units(n.max_amount_in.text, decimals: decimals) == max else { return .failure(.mismatch("amount")) }
        guard tx.receiver == contract else { return .failure(.mismatch("token contract")) }
        let wrap = i.token == "NEAR"
        var acts = tx.actions
        func storage(for who: String) -> Bool {
            guard let first = acts.first, case .call(let m, let args, let dep) = first, m == "storage_deposit", let a = json(args),
                  a["account_id"] as? String == who, a.count <= 2, a["registration_only"] == nil || a["registration_only"] as? Bool == true,
                  compare(dep, maxStorageDeposit) <= 0 else { return false }
            acts.removeFirst()
            return true
        }
        if wrap { _ = storage(for: account) }
        _ = storage(for: deposit)
        if wrap {
            guard let first = acts.first, case .call(let m, let args, let dep) = first, m == "near_deposit", json(args)?.isEmpty == true, dep == max else {
                return .failure(.mismatch("wrap"))
            }
            acts.removeFirst()
        }
        guard acts.count == 1, case .call(let m, let args, let dep) = acts[0], m == "ft_transfer", dep == "1",
              let a = json(args), a.count == 2, let to = a["receiver_id"] as? String, let amount = a["amount"] as? String else {
            return .failure(.mismatch("actions"))
        }
        guard to == deposit else { return .failure(.mismatch("receiver")) }
        guard amount == max else { return .failure(.mismatch("amount")) }
        return .success(Seen(signer: tx.signer, receiver: to, amount: amount, token: i.token))
    }
}
