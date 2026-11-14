import Foundation

/// The NEAR network on the phone: the one the server last confirmed (GET/PUT /v1/pay/network). Testnet until the app switches.
enum PayNetwork {
    /// "testnet" or "mainnet". The cards show each intent's own network.
    static var name: String { SharedStore.payNetwork == "mainnet" ? "mainnet" : "testnet" }
    /// The account suffix this network sends to: ".testnet", or ".near" on mainnet.
    static var accountSuffix: String { name == "mainnet" ? ".near" : ".testnet" }
    /// "NEAR testnet"
    static var label: String { "NEAR \(name)" }

    /// A typed account id as this network sends it: on testnet, "ana.near" is read as "ana.testnet".
    static func account(_ typed: String) -> String {
        guard name != "mainnet", typed.hasSuffix(".near") else { return typed }
        return String(typed.dropLast(5)) + accountSuffix
    }

    /// The NearBlocks page for a transaction, built on the phone from the intent's network.
    static func explorer(_ txHash: String, network: String) -> String {
        (network == "mainnet" ? "https://nearblocks.io/txns/" : "https://testnet.nearblocks.io/txns/") + txHash
    }
}

/// GET /v1/pay/network.
struct PayNetworkInfo: Decodable, Equatable {
    let network: String
    var mainnet_enabled: Bool?
    var account_id: String?
}

/// A payment proposal from /v1/pay/intents. The app shows these fields, and approve sends the same ones back.
struct PayIntent: Decodable, Equatable, Identifiable {
    let id: String
    let amount: String
    let token: String
    let recipient: String
    /// pending, sending, sent, failed, outcome_unknown, rejected or expired.
    let status: String
    let network: String
    let tx_hash: String?
    let explorer_url: String?
    let deep_link: String
    /// Never paid before: the card asks the owner to confirm the address, and the keyboard sends a Face ID proof.
    var new_recipient: Bool?
    /// Cross-chain: the real destination and the checked numbers.
    var xchain: XchainCard?

    /// The NearBlocks link, from the tx hash and network, not from the server's URL.
    var explorer: String? { tx_hash.map { PayNetwork.explorer($0, network: network) } }
}

/// The server will not build this: over a limit, or (for the app's own card) a new recipient without its key.
func needsApp(_ error: Error) -> Bool {
    if case APIError.http(403, _) = error { return true }
    return false
}

struct PayWallet: Decodable, Equatable {
    let account_id: String
    let status: String
    let network: String
    var balances: [String: String]?
}

/// POST /v1/pay/register.
struct PayRegistered: Decodable, Equatable {
    let account_id: String
    let network: String
    let status: String
}

/// Which AI answered a reply: in NEAR AI's TEE (`private`), with its attestation checked (`attested`).
enum PrivacyMark: Equatable {
    case verified, privateOnly

    static func weaker(_ a: PrivacyMark?, _ b: PrivacyMark?) -> PrivacyMark? {
        guard let a, let b else { return nil }
        return a == .verified ? b : a
    }

    init?(private isPrivate: Bool?, attested: Bool?) {
        guard isPrivate == true else { return nil }
        self = attested == true ? .verified : .privateOnly
    }
}

/// GET /v1/ai/attestation, for the proof screen.
struct AIAttestation: Decodable, Equatable {
    struct Model: Decodable, Equatable { let model: String; let ok: Bool; let checked_at: String?; let failure: String? }
    struct Signature: Decodable, Equatable { let model: String; let ok: Bool; let checked_at: String?; let failure: String? }
    let isPrivate: Bool
    let attested: Bool
    var provider: String?
    var tier: String?
    var verify_url: String?
    var models: [Model]?
    var last_signature: Signature?
    var method: [String]?
    var not_checked: [String]?

    enum CodingKeys: String, CodingKey {
        case isPrivate = "private", attested, provider, tier, verify_url, models, last_signature, method, not_checked
    }

    var mark: PrivacyMark? { PrivacyMark(private: isPrivate, attested: attested) }
}

/// A payment the app sent, for the keyboard's Insert line. Kept in the App Group; nothing secret.
struct PaySent: Codable, Equatable {
    let id: String
    /// "Sent 5 USDC to ana.testnet"
    let label: String
    /// What Insert types: "Sent you 5 USDC ✓ https://testnet.nearblocks.io/txns/…"
    let line: String
    let at: Date

    init(id: String, label: String, line: String, at: Date) {
        self.id = id
        self.label = label
        self.line = line
        self.at = at
    }

    init(_ i: PayIntent, at: Date) {
        id = i.id
        label = "Sent \(i.amount) \(i.token) to \(i.recipient)"
        line = "Sent you \(i.amount) \(i.token) \u{2713}" + (i.explorer.map { " \($0)" } ?? "")
        self.at = at
    }

    /// The keyboard offers Insert for this long after the send.
    static let life: TimeInterval = 30 * 60
}

extension APIClient {
    /// The keyboard proposes; only the app can approve.
    func createPayIntent(_ d: PayDraft) async throws -> PayIntent {
        try await send(request("POST", "/v1/pay/intents", body: ["amount": d.amount, "token": d.token, "recipient": d.recipient], tap: true),
                       as: PayIntent.self)
    }

    func payIntent(_ id: String) async throws -> PayIntent {
        try await send(request("GET", "/v1/pay/intents/\(id)"), as: PayIntent.self)
    }

    /// Asks the server to build the exact transaction. The app passes its approver key.
    func unsignedPay(_ i: PayIntent, approverKey: String?) async throws -> PayUnsigned {
        try await unsignedPay(i, approverKey: approverKey, proof: nil)
    }

    /// The keyboard passes `proof`: the phone key's signature over PayApproval.proofHash(i), made after Face ID. The server
    /// needs it (or the app's key) to build for a recipient never paid before.
    func unsignedPay(_ i: PayIntent, approverKey: String?, proof: Data?) async throws -> PayUnsigned {
        var r = try request("POST", "/v1/pay/intents/\(i.id)/unsigned", body: ["amount": i.amount, "token": i.token, "recipient": i.recipient],
                            tap: true, timeout: 40)
        if let approverKey { r.setValue(approverKey, forHTTPHeaderField: "X-Pay-Approver") }
        if let proof { r.setValue(proof.base64EncodedString(), forHTTPHeaderField: "X-Pay-Proof") }
        return try await send(r, as: PayUnsigned.self)
    }

    /// The phone's Ed25519 signature over sha256(tx). The server checks it and broadcasts once.
    func submitPay(_ id: String, signature: Data) async throws -> PayIntent {
        try await send(request("POST", "/v1/pay/intents/\(id)/submit", body: ["signature": signature.base64EncodedString()], tap: true, timeout: 40),
                       as: PayIntent.self)
    }

    func payNetwork() async throws -> PayNetworkInfo {
        try await send(request("GET", "/v1/pay/network"), as: PayNetworkInfo.self)
    }

    func setPayNetwork(_ network: String, approverKey: String) async throws -> PayNetworkInfo {
        var r = try request("PUT", "/v1/pay/network", body: ["network": network])
        r.setValue(approverKey, forHTTPHeaderField: "X-Pay-Approver")
        return try await send(r, as: PayNetworkInfo.self)
    }

    /// The phone's public key (64 hex). The account is its implicit id; testnet sends free test NEAR once.
    func registerPayKey(_ publicKeyHex: String, approverKey: String) async throws -> PayRegistered {
        var r = try request("POST", "/v1/pay/register", body: ["publicKey": publicKeyHex], timeout: 40)
        r.setValue(approverKey, forHTTPHeaderField: "X-Pay-Approver")
        return try await send(r, as: PayRegistered.self)
    }

    func rejectPay(_ id: String) async throws -> PayIntent {
        try await send(request("POST", "/v1/pay/intents/\(id)/reject"), as: PayIntent.self)
    }

    /// A new approver key. The server keeps only its hash.
    func registerApprover(current: String?) async throws -> String {
        struct Out: Decodable { let approver_key: String }
        var r = try request("POST", "/v1/pay/approver")
        if let current { r.setValue(current, forHTTPHeaderField: "X-Pay-Approver") }
        return try await send(r, as: Out.self).approver_key
    }

    func payWallet() async throws -> PayWallet {
        try await send(request("GET", "/v1/pay/wallet", timeout: 40), as: PayWallet.self)
    }

    func aiAttestation() async throws -> AIAttestation {
        try await send(request("GET", "/v1/ai/attestation", timeout: 30), as: AIAttestation.self)
    }
}
