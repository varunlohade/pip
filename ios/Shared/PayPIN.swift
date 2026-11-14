import CommonCrypto
import CryptoKit
import Foundation
import Security

/// Pip's own 6-digit payment PIN: the keyboard's only way to approve (Face ID in a keyboard hangs or does nothing on a real phone).
/// The PIN is never stored. PBKDF2-HMAC-SHA256 turns it into an AES-GCM key that seals the raw signing key; the sealed copy sits
/// in the shared Keychain group without a biometry flag, so the keyboard can read it. Five wrong PINs lock it until Face ID in the app.
enum PayPIN {
    static let length = 6
    static let maxTries = 5
    static let rounds: UInt32 = 210_000

    static func isValid(_ pin: String) -> Bool { pin.count == length && pin.allSatisfy { $0.isASCII && $0.isNumber } }

    /// What the Keychain holds: salt, nonce and AES-GCM ciphertext with its tag. No PIN, no key.
    struct Sealed: Codable, Equatable {
        var salt: Data
        var nonce: Data
        var box: Data
        var rounds: UInt32
    }

    static func derive(_ pin: String, salt: Data, rounds: UInt32) -> SymmetricKey? {
        var out = [UInt8](repeating: 0, count: 32)
        let pinBytes = Array(pin.utf8)
        let status = salt.withUnsafeBytes { s in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pin, pinBytes.count,
                                 s.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds, &out, out.count)
        }
        defer { for i in out.indices { out[i] = 0 } }
        return status == kCCSuccess ? SymmetricKey(data: out) : nil
    }

    /// Seals `raw` under the PIN. The account id is bound in as associated data, so a sealed key cannot pose as another account.
    static func seal(_ raw: Data, pin: String, account: String, rounds: UInt32 = rounds) -> Sealed? {
        guard isValid(pin) else { return nil }
        var salt = Data(count: 16)
        guard salt.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }) == errSecSuccess,
              let key = derive(pin, salt: salt, rounds: rounds),
              let box = try? AES.GCM.seal(raw, using: key, nonce: AES.GCM.Nonce(), authenticating: Data(account.utf8)),
              let ct = box.combined else { return nil }
        return Sealed(salt: salt, nonce: Data(box.nonce), box: ct, rounds: rounds)
    }

    /// The raw key, or nil for a wrong PIN.
    static func open(_ s: Sealed, pin: String, account: String) -> PINKey? {
        guard isValid(pin), let key = derive(pin, salt: s.salt, rounds: s.rounds),
              let box = try? AES.GCM.SealedBox(combined: s.box),
              var raw = try? AES.GCM.open(box, using: key, authenticating: Data(account.utf8)) else { return nil }
        defer { raw.resetBytes(in: 0..<raw.count) }
        return PINKey(raw)
    }
}

/// The opened signing key, held only for one approval. `wipe()` zeroes the bytes (best effort: CryptoKit keeps its own copy
/// while a signature is made, and drops it right after).
final class PINKey {
    private var bytes: [UInt8]

    init(_ raw: Data) { bytes = Array(raw) }
    deinit { wipe() }

    var isWiped: Bool { bytes.allSatisfy { $0 == 0 } }

    func publicKeyHex() -> String? {
        (try? Curve25519.Signing.PrivateKey(rawRepresentation: bytes)).map { PayKey.accountID($0.publicKey) }
    }

    func sign(_ hash: Data) -> Data? {
        guard hash.count == 32, !isWiped, let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: bytes) else { return nil }
        return try? key.signature(for: hash)
    }

    func wipe() { for i in bytes.indices { bytes[i] = 0 } }
}

/// The sealed key, the try count and the "Face ID failed last time" mark. PINKeychain is the real one; tests pass memory.
protocol PayPINStore {
    func get(_ item: PayPINItem) -> Data?
    @discardableResult func set(_ item: PayPINItem, _ value: Data?) -> OSStatus
    /// The Keychain's answer for the item, for Keyboard status: errSecSuccess, errSecItemNotFound, or why it could not look.
    func status(_ item: PayPINItem) -> OSStatus
}

enum PayPINItem: String, CaseIterable { case sealed, tries, faceFailed }

/// Shared Keychain group, readable while the phone is unlocked, never synced or backed up, no Face ID flag.
struct PINKeychain: PayPINStore {
    static let service = "com.orseliyas.pip.paypin"
    var group = AppConfig.keychainGroup

    private func query(_ item: PayPINItem) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
         kSecAttrAccount as String: item.rawValue, kSecAttrAccessGroup as String: group]
    }

    func get(_ item: PayPINItem) -> Data? {
        var q = query(item)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }

    func status(_ item: PayPINItem) -> OSStatus {
        var q = query(item)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &out)
    }

    func set(_ item: PayPINItem, _ value: Data?) -> OSStatus {
        SecItemDelete(query(item) as CFDictionary)
        guard let value else { return errSecSuccess }
        var q = query(item)
        q[kSecValueData as String] = value
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(q as CFDictionary, nil)
    }
}

enum PINUnlock {
    case ready(PINKey)
    case wrong(left: Int)
    case locked
    case notSet
}

/// The PIN rules: set it (the app, after Face ID read the key), open it (the keyboard), count wrong tries, lock at five.
struct PayPINVault {
    var store: PayPINStore = PINKeychain()
    var accountID: () -> String? = { SharedStore.payPublicKey }
    /// The pause after a wrong PIN. Tests make it zero.
    var wrongDelay: Duration = .seconds(1)
    /// PBKDF2 rounds for a new seal. Tests make it small.
    var rounds: UInt32 = PayPIN.rounds

    var isSet: Bool { sealed != nil }
    /// The Keychain's answer for the sealed key, for Keyboard status.
    var sealedStatus: OSStatus { store.status(.sealed) }
    var tries: Int { store.get(.tries).flatMap { Int(String(decoding: $0, as: UTF8.self)) } ?? 0 }
    var isLocked: Bool { tries >= PayPIN.maxTries }

    /// Face ID failed in the keyboard last time: open the PIN pad straight away.
    var faceFailedLast: Bool {
        get { store.get(.faceFailed) != nil }
        nonmutating set { store.set(.faceFailed, newValue ? Data([1]) : nil) }
    }

    private var sealed: PayPIN.Sealed? { store.get(.sealed).flatMap { try? JSONDecoder().decode(PayPIN.Sealed.self, from: $0) } }

    /// The app, after Face ID read `raw`: seal it under the new PIN and start the count again.
    @discardableResult
    func set(pin: String, raw: Data) -> Bool {
        guard let account = accountID(), PINKey(raw).publicKeyHex() == account,
              let s = PayPIN.seal(raw, pin: pin, account: account, rounds: rounds),
              let data = try? JSONEncoder().encode(s), store.set(.sealed, data) == errSecSuccess else { return false }
        resetTries()
        return true
    }

    /// The app, after Face ID: payments in the keyboard work again.
    func resetTries() { store.set(.tries, nil) }

    func remove() { for item in PayPINItem.allCases { store.set(item, nil) } }

    /// The keyboard: the key for this PIN, or how many tries are left. The count goes up before the slow check, so killing the
    /// keyboard mid-check still spends the try.
    func unlock(_ pin: String) async -> PINUnlock {
        guard let s = sealed, let account = accountID() else { return .notSet }
        guard !isLocked else { return .locked }
        let spent = tries + 1
        store.set(.tries, Data(String(spent).utf8))
        if let key = PayPIN.open(s, pin: pin, account: account), key.publicKeyHex() == account {
            resetTries()
            return .ready(key)
        }
        try? await Task.sleep(for: wrongDelay)
        return spent >= PayPIN.maxTries ? .locked : .wrong(left: PayPIN.maxTries - spent)
    }
}
