import Foundation

// NEAR Intents beyond paying someone: swaps in the owner's own wallet, live previews, and receiving (requests and top-ups).
// The server parses, quotes and checks every number (server/src/pay/xchain); the phone shows its strings as they are.

/// One chain chip: the title shown and the words the server reads ("on base").
struct ChainChoice: Equatable, Hashable {
    let title: String
    let words: String

    /// The chains a payer can pay a request from.
    static let payer: [ChainChoice] = [
        .init(title: "Base", words: "base"), .init(title: "Ethereum", words: "ethereum"), .init(title: "Solana", words: "solana"),
        .init(title: "Arbitrum", words: "arbitrum"), .init(title: "Tron", words: "tron"), .init(title: "Polygon", words: "polygon"),
        .init(title: "BNB", words: "bsc"),
    ]
}

/// The keyboard's cheap test for a swap, a request or a top-up before it asks the server.
enum IntentsDetect {
    private static let re = try! NSRegularExpression(
        pattern: #"\b(?:(?:swap|convert|exchange|trade)\s+(?:my\s+)?\$?\s?\d[\d.]*\s*[a-z][a-z0-9]{1,9}\s+(?:on\s+near\s+)?(?:to|into|for)\s+[a-z][a-z0-9]{1,9}|(?:request|ask\s+(?:@?[a-z0-9_.-]+\s+)?for|charge\s+@?[a-z0-9_.-]+)\s+\$?\s?\d[\d.]*\s*(?:usdc|usdt)|top\s*-?\s*up\s+(?:my\s+)?(?:pip|wallet))\b[^\n]{0,40}"#,
        options: [.caseInsensitive])

    static func candidate(_ text: String) -> String? {
        let ns = text as NSString
        guard let m = re.matches(in: text, range: NSRange(location: 0, length: ns.length)).last else { return nil }
        return String(ns.substring(with: m.range).trimmingCharacters(in: .whitespaces).prefix(500))
    }
}

/// POST /v1/pay/xchain/request: a checked deposit address on the payer's chain that delivers to the owner's NEAR account.
/// A preview (testnet) has the numbers but no deposit address. Pip never moves money here.
struct RequestCard: Decodable, Equatable {
    struct Origin: Decodable, Equatable { let chain: String; let chain_name: String }
    struct Ref: Decodable, Equatable { let id: String; let status: String }
    var verified: Bool
    var notVerified: [String] = []
    var kind = "request"
    var preview = false
    var action: String?
    var numbers: XchainNumbers?
    var origin: Origin?
    var deposit_address: String?
    var valid_until: String?
    var refund_note: String?
    var slippageBps: Int?
    var routePath: [String] = []
    var request: Ref?

    enum CodingKeys: String, CodingKey {
        case verified, not_verified, error, kind, preview, action, numbers, origin, deposit_address, valid_until, refund_note, slippage_bps, route_path, request
    }

    init(verified: Bool, kind: String, numbers: XchainNumbers?, origin: Origin?, deposit_address: String?, valid_until: String?, request: Ref?, preview: Bool = false, action: String? = nil) {
        self.verified = verified
        self.kind = kind
        self.numbers = numbers
        self.origin = origin
        self.deposit_address = deposit_address
        self.valid_until = valid_until
        self.request = request
        self.preview = preview
        self.action = action
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        verified = try c.decodeIfPresent(Bool.self, forKey: .verified) ?? false
        notVerified = try c.decodeIfPresent([String].self, forKey: .not_verified) ?? []
        if let e = try c.decodeIfPresent(String.self, forKey: .error) { notVerified.append(e) }
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "request"
        preview = try c.decodeIfPresent(Bool.self, forKey: .preview) ?? false
        action = try c.decodeIfPresent(String.self, forKey: .action)
        numbers = try c.decodeIfPresent(XchainNumbers.self, forKey: .numbers)
        origin = try c.decodeIfPresent(Origin.self, forKey: .origin)
        deposit_address = try c.decodeIfPresent(String.self, forKey: .deposit_address)
        valid_until = try c.decodeIfPresent(String.self, forKey: .valid_until)
        refund_note = try c.decodeIfPresent(String.self, forKey: .refund_note)
        slippageBps = try c.decodeIfPresent(Int.self, forKey: .slippage_bps)
        routePath = try c.decodeIfPresent([String].self, forKey: .route_path) ?? []
        request = try c.decodeIfPresent(Ref.self, forKey: .request)
    }

    /// A real request: checked, with a deposit address and an id to track.
    var live: Bool { verified && !preview && deposit_address != nil && request != nil }
    var topUp: Bool { kind == "topup" }
    var validUntil: Date? { valid_until.flatMap { Self.iso.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) } }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

/// GET /v1/pay/xchain/requests/:id.
struct RequestStatus: Decodable, Equatable {
    struct Got: Decodable, Equatable { let text: String; let symbol: String }
    let status: String
    var received: Got?
    var refund_reason: String?

    /// No more changes after this.
    var done: Bool { ["received", "refunded", "failed", "expired", "incomplete_deposit"].contains(status) }
}

/// The request card's lines, from the server's strings.
struct RequestText: Equatable {
    let title: String
    let pays: String
    let gets: String
    let slippage: String
    let path: String
    let refund: String
    /// Why there is no address to share, or nil.
    let blocked: String?

    init(_ card: RequestCard) {
        let chain = card.origin?.chain_name ?? "another chain"
        if let n = card.numbers {
            let a = n.max_amount_in
            title = card.topUp ? "Top up \(a.text) \(a.symbol) from \(chain)" : "Request \(a.text) \(a.symbol) on \(chain)"
            pays = card.topUp ? "You pay exactly \(a.text) \(a.symbol) on \(chain)" : "They pay exactly \(a.text) \(a.symbol) on \(chain)"
            let out = n.min_amount_out ?? n.amount_out
            gets = "You get at least \(out.text) \(out.symbol) in your Pip wallet"
        } else {
            title = card.topUp ? "Top up from \(chain)" : "Request on \(chain)"
            pays = "No price yet"
            gets = ""
        }
        slippage = "Slippage: up to " + XchainCardText.percent(card.slippageBps ?? 100)
        path = card.routePath.joined(separator: " \u{2192} ")
        refund = card.refund_note ?? "If it fails, NEAR Intents refunds it to your Pip account's NEAR Intents balance."
        if !card.verified {
            blocked = "Pip could not check this price: " + (card.notVerified.isEmpty ? "no reason given" : card.notVerified.joined(separator: "; "))
        } else if card.preview {
            blocked = card.action ?? "Preview only. There is no deposit address yet."
        } else if !card.live {
            blocked = "This quote is missing details, so Pip will not share it."
        } else {
            blocked = nil
        }
    }

    /// What Insert types in the chat: "Pay 5 USDC on Base to 0x… (via NEAR Intents, arrives in my Pip wallet, valid until 4:45 PM)".
    static func chatLine(_ card: RequestCard, timeZone: TimeZone = .current) -> String? {
        guard card.live, let n = card.numbers, let to = card.deposit_address, let chain = card.origin?.chain_name else { return nil }
        let until = card.validUntil.map { ", valid until " + time($0, timeZone: timeZone) } ?? ""
        return "Pay \(n.max_amount_in.text) \(n.max_amount_in.symbol) on \(chain) to \(to) (via NEAR Intents, arrives in my Pip wallet\(until))"
    }

    static func time(_ d: Date, timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "h:mm a"
        return f.string(from: d)
    }

    static func status(_ s: RequestStatus) -> String {
        switch s.status {
        case "waiting_for_payment": return "Waiting for payment\u{2026}"
        case "deposit_seen", "arriving": return "Payment seen. Arriving\u{2026}"
        case "received": return s.received.map { "Received \($0.text) \($0.symbol) \u{2713}" } ?? "Received \u{2713}"
        case "refunded": return "Refunded to your NEAR Intents balance." + (s.refund_reason.map { " (\($0))" } ?? "")
        case "incomplete_deposit": return "They paid less than asked. NEAR Intents refunds it to your NEAR Intents balance."
        case "expired": return "This request expired. Make a new one."
        case "failed": return "It did not go through. NEAR Intents refunds it to your NEAR Intents balance."
        default: return "Checking\u{2026}"
        }
    }
}

/// The bar title for a swap or a preview card, or nil for a plain cross-chain card.
enum SwapText {
    static func title(_ p: PayPanel) -> String? {
        if let r = p.request { return RequestText(r).title }
        guard let card = p.xchain, card.swap || card.preview else { return nil }
        if card.preview { return XchainCardText.previewTitle }
        guard let n = card.numbers else { return "Swap" }
        if p.phase == .sent { return p.swap.map(line) ?? "Swap sent" }
        return "Swap \(n.max_amount_in.text) \(XchainCardText.origin(n.max_amount_in.symbol)) to \(n.amount_out.symbol)"
    }

    static func line(_ s: SwapState) -> String {
        switch s {
        case .swapping: return "Swapping\u{2026}"
        case .delivered: return "Swapped \u{2713}"
        case .refunded(let why): return "Refunded. The money is back in your NEAR wallet." + (why.map { " (\($0))" } ?? "")
        case .failed(let s): return s
        }
    }
}

/// GET /v1/pay/addresses.
struct OwnAddresses: Decodable, Equatable {
    struct Saved: Decodable, Equatable { let chain: String; let chain_name: String; let address: String }
    struct Chain: Decodable, Equatable, Hashable { let id: String; let name: String }
    let addresses: [Saved]
    let chains: [Chain]
}

extension APIClient {
    /// A request or top-up: the payer's chain and the amount they pay. The server quotes a deposit address (mainnet) or a preview.
    func requestPay(_ p: XchainParsed) async throws -> RequestCard {
        let body = ["amount": p.amount ?? "", "token": p.token ?? "USDC", "chain": p.chain ?? "", "kind": p.kind == "topup" ? "topup" : "request"]
        do {
            return try await send(request("POST", "/v1/pay/xchain/request", body: body, tap: true, timeout: 40), as: RequestCard.self)
        } catch APIError.http(422, let raw) {
            return try JSONDecoder().decode(RequestCard.self, from: Data(raw.utf8))
        }
    }

    func requestStatus(_ id: String) async throws -> RequestStatus {
        try await send(request("GET", "/v1/pay/xchain/requests/\(id)", timeout: 20), as: RequestStatus.self)
    }

    func ownAddresses() async throws -> OwnAddresses {
        try await send(request("GET", "/v1/pay/addresses"), as: OwnAddresses.self)
    }

    /// Only the app saves an address: swaps to other chains land there.
    func setOwnAddress(chain: String, address: String, approverKey: String) async throws {
        struct Out: Decodable { let chain: String }
        var r = try request("PUT", "/v1/pay/addresses", body: ["chain": chain, "address": address], tap: true)
        r.setValue(approverKey, forHTTPHeaderField: "X-Pay-Approver")
        _ = try await send(r, as: Out.self)
    }

    func deleteOwnAddress(chain: String, approverKey: String) async throws {
        struct Out: Decodable { let ok: Bool }
        var r = try request("DELETE", "/v1/pay/addresses/\(chain)", tap: true)
        r.setValue(approverKey, forHTTPHeaderField: "X-Pay-Approver")
        _ = try await send(r, as: Out.self)
    }
}
