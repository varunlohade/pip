import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// The phone's NEAR key. Pip is self-custodial: this Ed25519 key signs every payment, and the server only builds and broadcasts.
/// The implicit account id is the 32 public-key bytes in lower-case hex, the same on testnet and mainnet.
enum PayKey {
    static func accountID(_ publicKey: Curve25519.Signing.PublicKey) -> String { publicKey.rawRepresentation.hex }
}

enum SignResult: Equatable { case signed(Data), denied, unavailable }

/// One Face ID for one approval. `.ready` signs 32-byte hashes with the key read by that Face ID; the key lives only as long as
/// the closure, which the approval drops when it ends. `.failed` says why, for the card and the keyboard status screen.
enum PaySession { case ready((Data) -> Data?), failed(PayAuthIssue) }

/// Why Face ID did not give the key: the exact LocalAuthentication or Keychain code, never a secret.
struct PayAuthIssue: Equatable {
    /// "LAError -1004 notInteractive" or "OSStatus -25308".
    let code: String
    /// The owner said no (cancel, or a face that did not match).
    let declined: Bool

    init(status: OSStatus, la: Int?) {
        if let la {
            code = "LAError \(la) \(Self.name(la))"
            declined = [LAError.userCancel.rawValue, LAError.authenticationFailed.rawValue].contains(la)
        } else {
            code = "OSStatus \(status)"
            declined = [errSecUserCanceled, errSecAuthFailed].contains(status)
        }
    }

    static func name(_ la: Int) -> String {
        switch LAError.Code(rawValue: la) {
        case .authenticationFailed?: "authenticationFailed"
        case .userCancel?: "userCancel"
        case .userFallback?: "userFallback"
        case .systemCancel?: "systemCancel"
        case .passcodeNotSet?: "passcodeNotSet"
        case .appCancel?: "appCancel"
        case .invalidContext?: "invalidContext"
        case .notInteractive?: "notInteractive"
        case .biometryNotAvailable?: "biometryNotAvailable"
        case .biometryNotEnrolled?: "biometryNotEnrolled"
        case .biometryLockout?: "biometryLockout"
        default: "other"
        }
    }
}

/// One Face ID read of the key bytes. `la` is the LAError code when Face ID itself failed.
struct PayKeyRead {
    var raw: Data?
    var status: OSStatus
    var la: Int? = nil
    var issue: PayAuthIssue { PayAuthIssue(status: status, la: la) }
}

/// Signs the 32-byte transaction hash after Face ID. The app and the keyboard share one key (see PayKeychain).
protocol PaySigner {
    /// The account id of the key on this phone, or nil before setup. Reading it needs no Face ID.
    func accountID() -> String?
    func sign(_ hash: Data, prompt: String) async -> SignResult
    /// Face ID once, then the keyboard signs its approval proof and the transaction with the same read.
    func session(prompt: String) async -> PaySession
}

/// Where the raw key bytes live. PayKeychain is the real one; tests pass memory.
protocol PayKeyStorage {
    func save(_ raw: Data) -> OSStatus
    /// Asks for Face ID. No bytes, with the reason, when the owner cancels or the phone cannot ask.
    func load(prompt: String) async -> PayKeyRead
    func delete()
}

/// Makes, keeps and uses the key. The public key (not secret) sits in the App Group, so showing the account needs no Face ID.
struct PayKeyVault: PaySigner {
    var storage: PayKeyStorage = PayKeychain()
    var publicKeyHex: () -> String? = { SharedStore.payPublicKey }
    var setPublicKeyHex: (String?) -> Void = { SharedStore.payPublicKey = $0 }

    func accountID() -> String? { publicKeyHex() }

    /// The existing key's account, or a new key. Returns nil when the Keychain refused it (no passcode or no Face ID).
    func ensure() -> String? {
        if let id = accountID() { return id }
        let key = Curve25519.Signing.PrivateKey()
        guard storage.save(key.rawRepresentation) == errSecSuccess else { return nil }
        let id = PayKey.accountID(key.publicKey)
        setPublicKeyHex(id)
        return id
    }

    func sign(_ hash: Data, prompt: String) async -> SignResult {
        guard hash.count == 32, let id = accountID() else { return .unavailable }
        let read = await storage.load(prompt: prompt)
        guard let raw = read.raw, let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
            return read.issue.declined ? .denied : .unavailable
        }
        // The App Group copy of the public key must belong to this private key.
        guard PayKey.accountID(key.publicKey) == id, let sig = try? key.signature(for: hash) else { return .unavailable }
        return .signed(sig)
    }

    func session(prompt: String) async -> PaySession {
        guard let id = accountID() else { return .failed(PayAuthIssue(status: errSecItemNotFound, la: nil)) }
        let read = await storage.load(prompt: prompt)
        guard let raw = read.raw, let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else { return .failed(read.issue) }
        guard PayKey.accountID(key.publicKey) == id else { return .failed(PayAuthIssue(status: errSecDecode, la: nil)) }
        return .ready { hash in hash.count == 32 ? try? key.signature(for: hash) : nil }
    }

    /// The app only: Face ID, then the raw key bytes, to seal them under a new payment PIN.
    func rawKey(prompt: String) async -> PayKeyRead {
        guard accountID() != nil else { return PayKeyRead(raw: nil, status: errSecItemNotFound) }
        return await storage.load(prompt: prompt)
    }

    func forget() {
        storage.delete()
        setPublicKeyHex(nil)
    }
}

/// The key bytes in the Keychain group the app shares with the keyboard, so the keyboard can sign small sends to people paid
/// before. Every read needs Face ID with the currently enrolled faces (`.biometryCurrentSet`); the item exists only while a
/// passcode is set and never leaves this phone (no backup, no sync).
struct PayKeychain: PayKeyStorage {
    static let service = "com.orseliyas.pip.paykey"
    static let account = "ed25519"
    var group = AppConfig.keychainGroup

    private func query() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
         kSecAttrAccount as String: Self.account, kSecAttrAccessGroup as String: group]
    }

    func save(_ raw: Data) -> OSStatus {
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .biometryCurrentSet, &error) else {
            return errSecParam
        }
        SecItemDelete(query() as CFDictionary)
        var q = query()
        q[kSecValueData as String] = raw
        q[kSecAttrAccessControl as String] = access
        return SecItemAdd(q as CFDictionary, nil)
    }

    /// Face ID through LocalAuthentication first, so a failure has its exact LAError code; then the Keychain read reuses that
    /// evaluated context, with no second sheet.
    func load(prompt: String) async -> PayKeyRead {
        let ctx = LAContext()
        ctx.localizedReason = prompt
        ctx.localizedFallbackTitle = ""
        do {
            guard try await ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: prompt) else {
                return PayKeyRead(raw: nil, status: errSecAuthFailed)
            }
        } catch {
            return PayKeyRead(raw: nil, status: errSecAuthFailed, la: (error as NSError).code)
        }
        var q = query()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        q[kSecUseAuthenticationContext as String] = ctx
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        return PayKeyRead(raw: status == errSecSuccess ? out as? Data : nil, status: status)
    }

    func delete() { SecItemDelete(query() as CFDictionary) }

    /// True when the item is there. Reads attributes only, so it never asks for Face ID.
    func exists() -> Bool {
        var q = query()
        q[kSecReturnAttributes as String] = true
        let ctx = LAContext()
        ctx.interactionNotAllowed = true
        q[kSecUseAuthenticationContext as String] = ctx
        var out: CFTypeRef?
        let s = SecItemCopyMatching(q as CFDictionary, &out)
        return s == errSecSuccess || s == errSecInteractionNotAllowed
    }
}

/// POST /:id/unsigned. The server's bytes are checked on the phone before anything is signed.
struct PayUnsigned: Decodable, Equatable {
    let id: String
    let tx_base64: String
    let sign_hash_hex: String
    /// Cross-chain: the old quote was replaced. The intent below and `xchain` are the new card; it needs Face ID again.
    var requoted: Bool?
    var xchain: XchainCard?
    var amount: String?
    var token: String?
    var recipient: String?

    /// The intent as this answer has it (a re-quote changes the amount and the deposit account).
    func intent(updating i: PayIntent) -> PayIntent {
        PayIntent(id: i.id, amount: amount ?? i.amount, token: token ?? i.token, recipient: recipient ?? i.recipient, status: i.status,
                  network: i.network, tx_hash: nil, explorer_url: nil, deep_link: i.deep_link, new_recipient: i.new_recipient)
    }
}

/// Reads the transaction the server built and checks it against the card. A lying or buggy server cannot get a signature for
/// a different receiver, amount, token or signer: the phone signs only sha256 of bytes that passed this check.
enum PayTxCheck {
    struct Seen: Equatable {
        let signer: String
        let receiver: String
        let amount: String
        let token: String
    }

    enum Refusal: Error, Equatable { case unreadable, hashMismatch, mismatch(String) }

    /// What the card says when the server's transaction does not match it.
    static let refusedLine = "The payment did not match this card, so Pip did not sign it. Nothing was sent."

    static let usdcContracts = [
        "testnet": "3e2210e1184b45b64c8a434c0a7e7b23cc04ea7eb7a6c3c32520d03d4afcb8af",
        "mainnet": "17208628f84f5d6ad33f0da3bbbeb27ffcb398eac501a31bd6ad2011e36133a1",
    ]
    /// The most a storage_deposit may attach: 0.01 NEAR (the USDC contract asks 0.00125).
    static let maxStorageDeposit = "10000000000000000000000"

    /// The hash to sign, or why not.
    /// A cross-chain intent passes its `xchain` card: the transaction must fund exactly that quote.
    static func check(_ u: PayUnsigned, intent i: PayIntent, account: String, xchain: XchainCard? = nil) -> Result<(hash: Data, seen: Seen), Refusal> {
        guard let bytes = Data(base64Encoded: u.tx_base64), let tx = try? Tx(bytes) else { return .failure(.unreadable) }
        let hash = Data(SHA256.hash(data: bytes))
        guard hash.hex == u.sign_hash_hex.lowercased() else { return .failure(.hashMismatch) }
        guard tx.signer == account, tx.publicKey.hex == account else { return .failure(.mismatch("signer")) }
        if let card = xchain { return checkXchain(tx, intent: i, account: account, card: card).map { (hash, $0) } }
        let seen: Seen
        switch i.token {
        case "NEAR":
            guard tx.actions.count == 1, case .transfer(let deposit) = tx.actions[0] else { return .failure(.mismatch("actions")) }
            seen = Seen(signer: tx.signer, receiver: tx.receiver, amount: deposit, token: "NEAR")
            guard units(i.amount, decimals: 24) == deposit else { return .failure(.mismatch("amount")) }
        case "USDC":
            guard let contract = usdcContracts[i.network], tx.receiver == contract else { return .failure(.mismatch("token contract")) }
            var acts = tx.actions
            if acts.count == 2, case .call(let m, let args, let deposit) = acts[0], m == "storage_deposit" {
                guard let a = json(args), a["account_id"] as? String == i.recipient, a.count <= 2,
                      a["registration_only"] == nil || a["registration_only"] as? Bool == true,
                      compare(deposit, maxStorageDeposit) <= 0 else { return .failure(.mismatch("storage deposit")) }
                acts.removeFirst()
            }
            guard acts.count == 1, case .call(let m, let args, let deposit) = acts[0], m == "ft_transfer", deposit == "1",
                  let a = json(args), a.count == 2, let to = a["receiver_id"] as? String, let amount = a["amount"] as? String else {
                return .failure(.mismatch("actions"))
            }
            seen = Seen(signer: tx.signer, receiver: to, amount: amount, token: "USDC")
            guard units(i.amount, decimals: 6) == amount else { return .failure(.mismatch("amount")) }
        default:
            return .failure(.mismatch("token"))
        }
        guard seen.receiver == i.recipient else { return .failure(.mismatch("receiver")) }
        return .success((hash, seen))
    }

    /// "0.5" with 24 decimals → "500000000000000000000000". Nil for anything that is not a plain decimal that fits.
    static func units(_ amount: String, decimals: Int) -> String? {
        let parts = amount.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), parts.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }), !parts[0].isEmpty else { return nil }
        let frac = parts.count == 2 ? String(parts[1]) : ""
        guard frac.count <= decimals, parts.count == 1 || !frac.isEmpty else { return nil }
        let digits = (String(parts[0]) + frac + String(repeating: "0", count: decimals - frac.count)).drop { $0 == "0" }
        return digits.isEmpty ? "0" : String(digits)
    }

    static func json(_ d: Data) -> [String: Any]? { (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] }

    /// Compares two non-negative decimal strings with no leading zeros.
    static func compare(_ a: String, _ b: String) -> Int {
        a.count != b.count ? (a.count < b.count ? -1 : 1) : (a == b ? 0 : (a < b ? -1 : 1))
    }

    /// A NEAR Transaction (Borsh): signer, key, nonce, receiver, block hash, actions. Only Transfer and FunctionCall are read;
    /// any other action makes the whole transaction unreadable, so it is never signed.
    struct Tx {
        enum Action: Equatable { case transfer(String), call(String, Data, String) }
        let signer: String
        let publicKey: Data
        let receiver: String
        let actions: [Action]

        init(_ data: Data) throws {
            var r = Reader(bytes: [UInt8](data))
            signer = try r.string()
            guard try r.u8() == 0 else { throw Refusal.unreadable }
            publicKey = Data(try r.take(32))
            _ = try r.take(8)
            receiver = try r.string()
            _ = try r.take(32)
            let n = try r.u32()
            guard n <= 4 else { throw Refusal.unreadable }
            var acts: [Action] = []
            for _ in 0..<n {
                switch try r.u8() {
                case 2:
                    let method = try r.string()
                    let args = Data(try r.take(Int(try r.u32())))
                    _ = try r.take(8)
                    acts.append(.call(method, args, Self.decimal(try r.take(16))))
                case 3: acts.append(.transfer(Self.decimal(try r.take(16))))
                default: throw Refusal.unreadable
                }
            }
            guard r.atEnd else { throw Refusal.unreadable }
            actions = acts
        }

        /// A little-endian u128 as a decimal string.
        static func decimal(_ le: [UInt8]) -> String {
            var n = Array(le.reversed())
            var out = ""
            while n.contains(where: { $0 != 0 }) {
                var rem = 0
                for i in n.indices {
                    let cur = rem * 256 + Int(n[i])
                    n[i] = UInt8(cur / 10)
                    rem = cur % 10
                }
                out.append(Character(String(rem)))
            }
            return out.isEmpty ? "0" : String(out.reversed())
        }
    }

    private struct Reader {
        let bytes: [UInt8]
        var at = 0
        var atEnd: Bool { at == bytes.count }
        mutating func take(_ n: Int) throws -> [UInt8] {
            guard n >= 0, at + n <= bytes.count else { throw Refusal.unreadable }
            defer { at += n }
            return Array(bytes[at..<at + n])
        }
        mutating func u8() throws -> UInt8 { try take(1)[0] }
        mutating func u32() throws -> UInt32 { try take(4).reversed().reduce(0) { $0 << 8 | UInt32($1) } }
        mutating func string() throws -> String {
            let n = Int(try u32())
            guard n <= 256, let s = String(bytes: try take(n), encoding: .utf8) else { throw Refusal.unreadable }
            return s
        }
    }
}

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
