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

    enum CodingKeys: String, CodingKey { case verified, not_verified, numbers, destination, deposit_address, refund_to, error }

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
    }

    /// Approve needs a verified card with numbers and a deposit account.
    var approvable: Bool { verified && numbers != nil && deposit_address != nil && destination != nil }
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

    var trigger: String {
        switch self {
        case .ready(_, let t), .needsMainnet(let t), .refused(_, let t): t
        }
    }

    static let mainnetLine = "Cross-chain pay needs Mainnet. Switch in Pip Pay."
}

/// The keyboard's cheap test before it asks the server: a pay verb, an amount, a token word, "to", and something shaped like
/// an address on another chain (or a NEAR account paid in a token the plain flow does not send).
enum XchainDetect {
    private static let re = try! NSRegularExpression(
        pattern: #"\b(?:send|pay|transfer|give)\s+\d[\d.]*\s*([a-z][a-z0-9]{1,9})\b[^\n]{0,40}?\bto\s+@?(0x[0-9a-f]{40}|bc1[a-z0-9]{20,90}|[13][1-9a-z]{25,34}|t[1-9a-z]{33}|r[1-9a-z]{24,34}|[1-9a-z]{32,44}|[a-z0-9_-]+(?:\.[a-z0-9_-]+)*\.near)\b[^\n]{0,60}"#,
        options: [.caseInsensitive])

    /// The words to send to /v1/pay/xchain/parse, or nil. A plain NEAR send (PayDetect) is never a cross-chain ask.
    static func candidate(_ text: String) -> String? {
        guard PayDetect.detect(text) == nil else { return nil }
        let ns = text as NSString
        guard let m = re.matches(in: text, range: NSRange(location: 0, length: ns.length)).last else { return nil }
        let token = ns.substring(with: m.range(at: 1)).lowercased()
        let to = ns.substring(with: m.range(at: 2)).lowercased()
        if to.hasSuffix(".near"), ["near", "usdc"].contains(token) { return nil }
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
    /// Why Approve is off, or nil.
    let blocked: String?

    init(_ card: XchainCard) {
        let n = card.numbers, d = card.destination
        let who = d.map { Self.short($0.recipient) } ?? "The recipient"
        let chain = d?.chain_name ?? "the other chain"
        if let n {
            if n.mode == "exact_in", let min = n.min_amount_out {
                gets = "\(who) gets at least \(min.text) \(min.symbol) on \(chain)"
            } else {
                gets = "\(who) gets exactly \(n.amount_out.text) \(n.amount_out.symbol) on \(chain)"
            }
            pays = "You pay at most \(n.max_amount_in.text) \(Self.origin(n.max_amount_in.symbol)) from your NEAR wallet"
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
        if !card.verified {
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

/// First time paying an address: the owner taps how it ends (one of three) before Face ID.
struct AddressConfirm: Equatable {
    let address: String
    let options: [String]
    var picked: String?

    var answer: String { String(address.suffix(4)) }
    var confirmed: Bool { picked == answer }

    init(_ address: String) {
        self.address = address
        let real = String(address.suffix(4))
        let chars = Array(address)
        var decoys: [String] = []
        // Other 4-character runs of the same address look alike, which is the point: read the real end.
        var at = max(0, chars.count - 8)
        while decoys.count < 2, at >= 0 {
            let run = String(chars[at..<min(at + 4, chars.count)])
            if run.count == 4, run != real, !decoys.contains(run) { decoys.append(run) }
            at -= 3
        }
        let pool = Array("0123456789abcdef")
        let base = real.count == 4 ? Array(real) : Array("0000")
        var k = 0
        while decoys.count < 2 {
            var c = base
            let pos = 3 - k % 4
            let idx = pool.firstIndex(of: Character(c[pos].lowercased())) ?? 0
            c[pos] = pool[(idx + 1 + k) % pool.count]
            let s = String(c)
            if s != real, !decoys.contains(s) { decoys.append(s) }
            k += 1
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

    /// A checked quote, exact output by default. A 422 refusal comes back as an unverified card with the server's reason.
    func quoteXchain(_ p: XchainParsed) async throws -> XchainQuote {
        var body = ["amount": p.amount ?? "", "token": p.token ?? "", "chain": p.chain ?? "", "recipient": p.recipient ?? ""]
        if let f = p.from { body["from"] = f }
        do {
            return try await send(request("POST", "/v1/pay/xchain/quote", body: body, tap: true, timeout: 40), as: XchainQuote.self)
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
