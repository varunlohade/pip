import Foundation
import LocalAuthentication

/// The one place that names the NEAR network on the phone. A mainnet build changes only this.
enum PayNetwork {
    /// "testnet" or "mainnet". The server also says its network on every intent; the cards show the server's value.
    static let name = "testnet"
    /// The account suffix this build sends to: ".testnet", or ".near" on mainnet.
    static var accountSuffix: String { name == "mainnet" ? ".near" : ".testnet" }
    /// "NEAR testnet"
    static var label: String { "NEAR \(name)" }

    /// A typed account id as this build sends it: on testnet, "ana.near" is read as "ana.testnet".
    static func account(_ typed: String) -> String {
        guard name != "mainnet", typed.hasSuffix(".near") else { return typed }
        return String(typed.dropLast(5)) + accountSuffix
    }
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
    /// Pending only: may the keyboard send this with its capped key? Over the limit or a new recipient opens the app.
    var keyboard: KeyboardCheck?

    struct KeyboardCheck: Decodable, Equatable {
        let ok: Bool
        /// not_set_up, new_recipient or over_limit.
        var reason: String?
        /// What the keyboard may still send today in this token.
        var left: String?
        let paid_before: Int
    }
}

/// The server said this needs the app: a new recipient, over the keyboard limit, or no keyboard key.
func needsApp(_ error: Error) -> Bool {
    if case APIError.http(403, let body) = error { return body.contains("needs_app") }
    return false
}

enum AuthResult: Equatable { case approved, denied, unavailable }

/// Face ID, or the passcode when Face ID is off or fails.
protocol Authenticator {
    func confirm(_ reason: String) async -> AuthResult
}

struct DeviceOwnerAuth: Authenticator {
    func confirm(_ reason: String) async -> AuthResult {
        let ctx = LAContext()
        var error: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return .unavailable }
        do {
            return try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) ? .approved : .denied
        } catch let e as LAError where [.notInteractive, .biometryNotAvailable, .passcodeNotSet, .biometryNotEnrolled].contains(e.code) {
            return .unavailable
        } catch {
            return .denied
        }
    }
}

struct PayWallet: Decodable, Equatable {
    let account_id: String
    let status: String
    let network: String
    var balances: [String: String]?
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

    init(_ i: PayIntent, at: Date) {
        id = i.id
        label = "Sent \(i.amount) \(i.token) to \(i.recipient)"
        line = "Sent you \(i.amount) \(i.token) \u{2713}" + (i.explorer_url.map { " \($0)" } ?? "")
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

    /// Sends the exact fields the card showed, with the app's approver key.
    func approvePay(_ i: PayIntent, approverKey: String) async throws -> PayIntent {
        var r = try request("POST", "/v1/pay/intents/\(i.id)/approve", body: ["amount": i.amount, "token": i.token, "recipient": i.recipient],
                            timeout: 40)
        r.setValue(approverKey, forHTTPHeaderField: "X-Pay-Approver")
        return try await send(r, as: PayIntent.self)
    }

    /// The keyboard's own approve, with the capped keyboard key. A 403 with needs_app means: open the app.
    func keyboardApprovePay(_ i: PayIntent, keyboardKey: String) async throws -> PayIntent {
        var r = try request("POST", "/v1/pay/intents/\(i.id)/keyboard-approve", body: ["amount": i.amount, "token": i.token, "recipient": i.recipient],
                            tap: true, timeout: 40)
        r.setValue(keyboardKey, forHTTPHeaderField: "X-Pay-Keyboard")
        return try await send(r, as: PayIntent.self)
    }

    /// Made by the app with the approver key. The server caps it to these daily limits and to recipients paid before.
    func setKeyboardPay(usdcDaily: String, nearDaily: String, approverKey: String) async throws -> (key: String, usdc: String, near: String) {
        struct Out: Decodable { let keyboard_key: String; let limits: [String: String] }
        var r = try request("POST", "/v1/pay/keyboard", body: ["usdc_daily": usdcDaily, "near_daily": nearDaily])
        r.setValue(approverKey, forHTTPHeaderField: "X-Pay-Approver")
        let o = try await send(r, as: Out.self)
        return (o.keyboard_key, o.limits["USDC"] ?? usdcDaily, o.limits["NEAR"] ?? nearDaily)
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
