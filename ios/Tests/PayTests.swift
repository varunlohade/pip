import CryptoKit
import Security
import XCTest
@testable import Pip

final class PayDetectTests: XCTestCase {
    func testReadsTheOneShape() {
        let d = PayDetect.detect("send 5 USDC to ana.testnet")
        XCTAssertEqual(d, PayDraft(amount: "5", token: "USDC", recipient: "ana.testnet", trigger: "send 5 USDC to ana.testnet"))
        XCTAssertEqual(d?.label, "Send 5 USDC to ana.testnet")
        XCTAssertEqual(PayDetect.detect("Send 0.5 near to Bob.testnet.")?.recipient, "bob.testnet")
        XCTAssertEqual(PayDetect.detect("Send 0.5 near to Bob.testnet.")?.token, "NEAR")
        XCTAssertEqual(PayDetect.detect("ok, pay 2.25 usdc to shop-1.testnet thanks")?.amount, "2.25")
        XCTAssertEqual(PayDetect.detect("send 5usdc to @ana.testnet")?.recipient, "ana.testnet")
    }

    func testNearAccountsAreShownAsTestnet() {
        let d = PayDetect.detect("send 5 USDC to ana.near")
        XCTAssertEqual(d?.recipient, "ana.testnet")
        XCTAssertEqual(d?.label, "Send 5 USDC to ana.testnet")
    }

    func testLeavesOtherTextAlone() {
        for t in ["send 5 USDC to ana", "send five USDC to ana.testnet", "send 5 ETH to ana.testnet", "send 0 USDC to ana.testnet",
                  "I sent 5 USDC to ana.testnet", "send 5 USDC to ana.com", "send 1.1234567 USDC to ana.testnet", "send me the file"] {
            XCTAssertNil(PayDetect.detect(t), t)
        }
    }
}

@MainActor
final class KeyboardPayTests: XCTestCase {
    private var host: FakeHost!
    private var api: FakeAPI!
    private var store: FakeStore!
    private var signer: FakeSigner!
    private var model: KeyboardModel!

    override func setUp() async throws {
        host = FakeHost()
        api = FakeAPI()
        store = FakeStore()
        signer = FakeSigner()
        api.account = signer.accountID()!
        model = KeyboardModel(deps: .fake(api: api, store: store, signer: signer))
        model.host = host
        model.keyboardAppeared()
    }

    private func set(_ text: String) {
        host.text = text
        model.textChanged()
    }

    private func until(_ what: String, _ cond: () -> Bool) async {
        for _ in 0..<500 where !cond() { await Task.yield() }
        XCTAssertTrue(cond(), "timed out waiting for \(what)")
    }

    private func card() async {
        set("send 5 USDC to ana.near")
        model.perform(.pay)
        await until("the card") { model.payPanel != nil }
    }

    func testTheChipShowsFirstAndSendsNothingToSuggest() async {
        set("send 5 USDC to ana.near")
        let item = model.barItems.first
        XCTAssertEqual(item?.id, "pay")
        XCTAssertEqual(item?.title, "Send 5 USDC to ana.testnet")
        XCTAssertFalse(model.showsWordSlots)
        for _ in 0..<50 { await Task.yield() }
        XCTAssertFalse(api.calls.contains("suggest"))
    }

    func testKnownRecipientIsSignedInTheKeyboardAfterFaceID() async throws {
        await card()
        XCTAssertEqual(api.proposed.first?.recipient, "ana.testnet")
        XCTAssertEqual(store.payPending, PayIntent.fakeID)
        XCTAssertEqual(host.opened, [], "a keyboard send does not open the app")
        model.approvePayInKeyboard()
        await until("sent") { model.payPanel?.phase == .sent }
        XCTAssertEqual(signer.asks, 1)
        XCTAssertEqual(api.unsignedWith, [nil], "the keyboard never holds the approver key")
        let s = try XCTUnwrap(api.submitted.first)
        XCTAssertTrue(signer.key.publicKey.isValidSignature(s.signature, for: s.hash), "the phone signed sha256 of the built bytes")
        XCTAssertNil(store.payPending)
        model.insertKeyboardSent()
        XCTAssertEqual(host.text, "Sent you 5 USDC \u{2713} https://testnet.nearblocks.io/txns/7Hq2Xb9TfE3mNwq8RkLz5VdYc1pA6sGh1uJkP4")
        XCTAssertNil(model.payPanel)
    }

    func testALyingServerGetsNoSignature() async {
        api.tamper = { i in TestTx.forIntent(PayIntent.fake(PayDraft(amount: "500", token: i.token, recipient: i.recipient, trigger: "")), signer: self.api.account) }
        await card()
        model.approvePayInKeyboard()
        await until("refused") { model.payPanel?.phase == .failed(PayTxCheck.refusedLine) }
        XCTAssertEqual(signer.asks, 0, "refused before Face ID")
        XCTAssertEqual(api.submitted.count, 0)
        await until("reject") { api.rejected.count == 1 }
    }

    func testTheSameTypedAgainOffersTheChipAgain() async {
        api.newRecipient = true
        set("send 5 USDC to ana.testnet")
        model.perform(.pay)
        await until("the bar line") { model.bar == .done("Open Pip to approve") }
        XCTAssertNil(model.payItem, "no chip again for the same text")
        set("")
        set("send 5 USDC to ana.testnet")
        XCTAssertEqual(model.barItems.first?.id, "pay")
    }

    func testANewPaymentWinsOverTheLastReceipt() {
        store.paySent = PaySent(PayIntent.fake(PayDraft(amount: "5", token: "USDC", recipient: "ana.testnet", trigger: ""), status: "sent"),
                                at: Date(timeIntervalSince1970: 1_800_000_000))
        model.keyboardAppeared()
        set("send 5 USDC to ana.near ")
        XCTAssertEqual(model.barItems.first?.id, "pay")
    }

    func testNoSendWithoutFaceIDSuccess() async {
        signer.answer = .denied
        await card()
        model.approvePayInKeyboard()
        await until("the note") { model.payPanel?.note != nil }
        XCTAssertEqual(model.payPanel?.phase, .ready)
        XCTAssertEqual(api.submitted.count, 0)
    }

    func testNoFaceIDInTheKeyboardOpensTheApp() async {
        signer.answer = .unavailable
        await card()
        model.approvePayInKeyboard()
        await until("the app") { !host.opened.isEmpty }
        XCTAssertEqual(host.opened.first?.absoluteString, "pip://approve/\(PayIntent.fakeID)")
        XCTAssertEqual(api.submitted.count, 0)
        XCTAssertNil(model.payPanel)
    }

    func testNewRecipientOpensTheApp() async {
        api.newRecipient = true
        set("send 5 USDC to ana.testnet")
        model.perform(.pay)
        await until("the bar line") { model.bar == .done("Open Pip to approve") }
        XCTAssertNil(model.payPanel)
        XCTAssertEqual(host.opened.count, 1)
        XCTAssertEqual(store.payPending, PayIntent.fakeID, "the app finds it when opened by hand")
    }

    func testNoKeyOnThisPhoneOpensTheApp() async {
        signer.hasKey = false
        host.canOpen = true
        set("send 5 USDC to ana.testnet")
        model.perform(.pay)
        await until("the bar line") { model.bar == .done("Opening Pip\u{2026}") }
        XCTAssertNil(model.payPanel)
    }

    func testServerRefusalOpensTheApp() async {
        api.unsignedError = APIError.http(403, #"{"error":"over the 25 USDC daily limit"}"#)
        await card()
        model.approvePayInKeyboard()
        await until("the app") { !host.opened.isEmpty }
        XCTAssertNil(model.payPanel)
        XCTAssertEqual(signer.asks, 0)
    }

    func testRejectTellsTheServerAndSendsNothing() async {
        await card()
        model.rejectPayInKeyboard()
        await until("reject") { api.rejected.count == 1 }
        XCTAssertNil(model.payPanel)
        XCTAssertEqual(api.submitted.count, 0)
    }

    func testAnAppSendOffersItsLineOnce() {
        store.paySent = PaySent(PayIntent.fake(PayDraft(amount: "5", token: "USDC", recipient: "ana.testnet", trigger: ""), status: "sent"),
                                at: Date(timeIntervalSince1970: 1_800_000_000))
        model.keyboardAppeared()
        XCTAssertEqual(model.barItems.map(\.id), ["paid", "paid.insert"])
        model.perform(.insertPaid)
        XCTAssertTrue(host.text.hasPrefix("Sent you 5 USDC \u{2713} https://testnet.nearblocks.io/txns/"))
        XCTAssertNil(store.paySent)
    }
}

final class FakePayAPI: PayAPI {
    var intent = PayIntent.fake(PayDraft(amount: "5", token: "USDC", recipient: "ana.testnet", trigger: ""), newRecipient: true)
    var account = ""
    var tamper: ((Data) -> Data)?
    var info = PayNetworkInfo(network: "testnet", mainnet_enabled: true, account_id: nil)
    private(set) var unsignedWith: [String?] = []
    private(set) var submitted: [Data] = []
    private(set) var registered = 0
    private(set) var keys: [(network: String, key: String)] = []
    private(set) var rejected = 0
    var walletError: Error?
    var registerError: Error?
    func payIntent(_ id: String) async throws -> PayIntent { intent }
    func unsignedPay(_ i: PayIntent, approverKey: String?) async throws -> PayUnsigned {
        unsignedWith.append(approverKey)
        let honest = TestTx.forIntent(i, signer: account)
        return TestTx.unsigned(i.id, tamper?(honest) ?? honest)
    }
    func submitPay(_ id: String, signature: Data) async throws -> PayIntent {
        submitted.append(signature)
        return PayIntent.fake(PayDraft(amount: intent.amount, token: intent.token, recipient: intent.recipient, trigger: ""), status: "sent")
    }
    func rejectPay(_ id: String) async throws -> PayIntent { rejected += 1; return intent }
    func registerApprover(current: String?) async throws -> String { registered += 1; return "pap_new_key" }
    func payWallet() async throws -> PayWallet {
        if let walletError { throw walletError }
        return PayWallet(account_id: account, status: "ready", network: info.network, balances: ["NEAR": "0.2", "USDC": "0"])
    }
    func aiAttestation() async throws -> AIAttestation { AIAttestation(isPrivate: true, attested: true) }
    func payNetwork() async throws -> PayNetworkInfo { info }
    func setPayNetwork(_ network: String, approverKey: String) async throws -> PayNetworkInfo {
        info = PayNetworkInfo(network: network, mainnet_enabled: info.mainnet_enabled, account_id: keys.first { $0.network == network }?.key)
        return info
    }
    func registerPayKey(_ publicKeyHex: String, approverKey: String) async throws -> PayRegistered {
        if let registerError { throw registerError }
        keys.append((info.network, publicKeyHex))
        return PayRegistered(account_id: publicKeyHex, network: info.network, status: "ready")
    }
}

final class MemoryKeys: ApproverKeys {
    var key: String?
    func get() -> String? { key }
    func set(_ key: String?) -> Bool { self.key = key; return true }
}

/// The app's approval card: the server's bytes are checked, then Face ID signs them.
@MainActor
final class ApprovalModelTests: XCTestCase {
    func testApproveChecksTheTxThenSignsWithFaceID() async {
        let api = FakePayAPI(), signer = FakeSigner(), keys = MemoryKeys()
        api.account = signer.accountID()!
        var sent: [PaySent] = []
        let m = ApprovalModel(id: PayIntent.fakeID, api: api, signer: signer, keys: keys, recordSent: { sent.append($0) })
        await m.load()
        XCTAssertEqual(m.phase, .ready)
        XCTAssertEqual(m.mark, .verified)

        signer.answer = .denied
        await m.approve()
        XCTAssertEqual(api.submitted, [], "no Face ID, no submit")
        XCTAssertEqual(m.note, "Not approved. Nothing was sent.")

        signer.answer = nil
        await m.approve()
        XCTAssertEqual(api.registered, 1, "first approve makes the approver key")
        XCTAssertEqual(api.unsignedWith.last, "pap_new_key", "a new recipient needs the app's key")
        XCTAssertEqual(api.submitted.count, 1)
        XCTAssertEqual(m.phase, .sent)
        XCTAssertEqual(sent.first?.label, "Sent 5 USDC to ana.testnet")
    }

    func testMismatchIsRefusedBeforeFaceID() async {
        let api = FakePayAPI(), signer = FakeSigner()
        api.account = signer.accountID()!
        // The server swaps the recipient inside ft_transfer.
        api.tamper = { d in
            var out = d
            let r = out.range(of: Data(#""receiver_id":"ana.testnet""#.utf8))!
            out.replaceSubrange(r, with: Data(#""receiver_id":"eve.testnet""#.utf8))
            return out
        }
        let m = ApprovalModel(id: PayIntent.fakeID, api: api, signer: signer, keys: MemoryKeys(), recordSent: { _ in })
        await m.load()
        await m.approve()
        XCTAssertEqual(m.phase, .failed(PayTxCheck.refusedLine))
        XCTAssertEqual(signer.asks, 0)
        XCTAssertEqual(api.submitted, [])
        XCTAssertEqual(api.rejected, 1)
    }

    func testDeepLinkTakesOnlyAnIntentID() {
        XCTAssertEqual(PayApprovalRequest(url: URL(string: "pip://approve/\(PayIntent.fakeID)")!)?.id, PayIntent.fakeID)
        XCTAssertNil(PayApprovalRequest(url: URL(string: "pip://approve/../wallet")!))
        XCTAssertNil(PayApprovalRequest(url: URL(string: "pip://approve/\(PayIntent.fakeID)/x")!))
        XCTAssertNil(PayApprovalRequest(url: URL(string: "https://approve/\(PayIntent.fakeID)")!))
    }
}

/// The key bytes in memory, standing in for the Face ID Keychain item.
final class MemoryKeyStorage: PayKeyStorage {
    var raw: Data?
    var loadStatus = errSecSuccess
    func save(_ raw: Data) -> OSStatus { self.raw = raw; return errSecSuccess }
    func load(prompt: String) -> (Data?, OSStatus) { loadStatus == errSecSuccess ? (raw, raw == nil ? errSecItemNotFound : errSecSuccess) : (nil, loadStatus) }
    func delete() { raw = nil }
}

final class PayKeyTests: XCTestCase {
    private func vault(_ storage: MemoryKeyStorage) -> (PayKeyVault, () -> String?) {
        var pub: String?
        return (PayKeyVault(storage: storage, publicKeyHex: { pub }, setPublicKeyHex: { pub = $0 }), { pub })
    }

    func testKeyRoundTripsAndTheAccountIsItsPublicKeyHex() async throws {
        let storage = MemoryKeyStorage()
        let (v, pub) = vault(storage)
        let id = try XCTUnwrap(v.ensure())
        XCTAssertEqual(v.ensure(), id, "one key per phone")
        let back = try Curve25519.Signing.PrivateKey(rawRepresentation: XCTUnwrap(storage.raw))
        XCTAssertEqual(back.publicKey.rawRepresentation.hex, id)
        XCTAssertEqual(pub(), id)
        XCTAssertTrue(id.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil)
        v.forget()
        XCTAssertNil(storage.raw)
        XCTAssertNil(v.accountID())
    }

    /// RFC 8032 test 1 key, and the hash of the server-built NEAR transfer fixture below.
    func testSignatureOverAKnownHashVerifiesWithCryptoKit() async throws {
        let storage = MemoryKeyStorage()
        storage.raw = Data(hexString: "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")
        let v = PayKeyVault(storage: storage, publicKeyHex: { "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a" }, setPublicKeyHex: { _ in })
        let hash = try XCTUnwrap(Data(hexString: PayTxCheckTests.nearHash))
        guard case .signed(let sig) = await v.sign(hash, prompt: "t") else { return XCTFail("no signature") }
        XCTAssertEqual(sig.count, 64)
        let pk = try Curve25519.Signing.PublicKey(rawRepresentation: XCTUnwrap(Data(hexString: v.accountID()!)))
        XCTAssertTrue(pk.isValidSignature(sig, for: hash))
        XCTAssertFalse(pk.isValidSignature(sig, for: Data(repeating: 0, count: 32)))
    }

    func testCancelIsDeniedAndAMissingKeyIsUnavailable() async {
        let storage = MemoryKeyStorage()
        let (v, _) = vault(storage)
        _ = v.ensure()
        storage.loadStatus = errSecUserCanceled
        let cancelled = await v.sign(Data(repeating: 1, count: 32), prompt: "t")
        XCTAssertEqual(cancelled, .denied)
        storage.loadStatus = errSecSuccess
        storage.raw = nil
        let missing = await v.sign(Data(repeating: 1, count: 32), prompt: "t")
        XCTAssertEqual(missing, .unavailable)
    }

    /// The real item carries the passcode-only class and a Face ID access control. The simulator stores both but does not
    /// enforce them (a read there gets the bytes without Face ID), so enforcement is a device-only check.
    func testTheKeychainItemIsFaceIDBound() throws {
        let k = PayKeychain()
        defer { k.delete() }
        XCTAssertEqual(k.save(Data(repeating: 9, count: 32)), errSecSuccess)
        XCTAssertTrue(k.exists())
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: PayKeychain.service,
                                kSecAttrAccount as String: PayKeychain.account, kSecAttrAccessGroup as String: AppConfig.keychainGroup,
                                kSecReturnAttributes as String: true]
        var out: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(q as CFDictionary, &out), errSecSuccess)
        let attrs = try XCTUnwrap(out as? [String: Any])
        XCTAssertEqual(attrs[kSecAttrAccessible as String] as? String, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly as String)
        XCTAssertNotNil(attrs[kSecAttrAccessControl as String])
        XCTAssertEqual(attrs[kSecAttrAccessGroup as String] as? String, AppConfig.keychainGroup, "shared with the keyboard on purpose")
    }
}

final class PayTxCheckTests: XCTestCase {
    // Built by server/src/pay/phone/tx.ts buildTransfer for the RFC 8032 test 1 key, nonce 1001.
    static let pk = "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a"
    static let nearTx = "QAAAAGQ3NWE5ODAxODJiMTBhYjdkNTRiZmVkM2M5NjQwNzNhMGVlMTcyZjNkYWE2MjMyNWFmMDIxYTY4ZjcwNzUxMWEA11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURrpAwAAAAAAAAsAAABhbmEudGVzdG5ldONCnPEv9PhlWAqDSOinnPe6fSmqJqvtXlpnEc0z6SogAQAAAAMAAIDQdmbnDeFpAAAAAAAA"
    static let nearHash = "ff8def8a1bac328b4e17f2c58130ddefd789cf5bd47e07da1ac4dda8d3503f5a"
    static let usdcTx = "QAAAAGQ3NWE5ODAxODJiMTBhYjdkNTRiZmVkM2M5NjQwNzNhMGVlMTcyZjNkYWE2MjMyNWFmMDIxYTY4ZjcwNzUxMWEA11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURrpAwAAAAAAAEAAAAAzZTIyMTBlMTE4NGI0NWI2NGM4YTQzNGMwYTdlN2IyM2NjMDRlYTdlYjdhNmMzYzMyNTIwZDAzZDRhZmNiOGFm40Kc8S/0+GVYCoNI6Kec97p9Kaomq+1eWmcRzTPpKiACAAAAAg8AAABzdG9yYWdlX2RlcG9zaXQ1AAAAeyJhY2NvdW50X2lkIjoiYm9iLnRlc3RuZXQiLCJyZWdpc3RyYXRpb25fb25seSI6dHJ1ZX0A4FfrSBsAAAAASFY3GTzDQwAAAAAAAAACCwAAAGZ0X3RyYW5zZmVyMAAAAHsicmVjZWl2ZXJfaWQiOiJib2IudGVzdG5ldCIsImFtb3VudCI6IjUwMDAwMDAifQDgV+tIGwAAAQAAAAAAAAAAAAAAAAAAAA=="
    static let usdcHash = "903bde2005d517944324f0596236e6e3b62dc020d63ab4e02c62c588130ceb80"

    private func intent(_ amount: String, _ token: String, _ to: String, network: String = "testnet") -> PayIntent {
        PayIntent.fake(PayDraft(amount: amount, token: token, recipient: to, trigger: ""), network: network)
    }
    private func check(_ tx: String, _ hash: String, _ i: PayIntent, account: String = pk) -> Result<(hash: Data, seen: PayTxCheck.Seen), PayTxCheck.Refusal> {
        PayTxCheck.check(PayUnsigned(id: i.id, tx_base64: tx, sign_hash_hex: hash), intent: i, account: account)
    }

    func testServerBuiltTransactionsPassAndShowWhatTheyDo() throws {
        let n = try check(Self.nearTx, Self.nearHash, intent("0.5", "NEAR", "ana.testnet")).get()
        XCTAssertEqual(n.seen, .init(signer: Self.pk, receiver: "ana.testnet", amount: "500000000000000000000000", token: "NEAR"))
        XCTAssertEqual(n.hash.hex, Self.nearHash)
        let u = try check(Self.usdcTx, Self.usdcHash, intent("5", "USDC", "bob.testnet")).get()
        XCTAssertEqual(u.seen, .init(signer: Self.pk, receiver: "bob.testnet", amount: "5000000", token: "USDC"))
    }

    func testAnyMismatchIsRefused() {
        XCTAssertEqual(check(Self.nearTx, Self.nearHash, intent("5", "NEAR", "ana.testnet")).failure, .mismatch("amount"))
        XCTAssertEqual(check(Self.nearTx, Self.nearHash, intent("0.5", "NEAR", "eve.testnet")).failure, .mismatch("receiver"))
        XCTAssertEqual(check(Self.nearTx, Self.nearHash, intent("0.5", "USDC", "ana.testnet")).failure, .mismatch("token contract"))
        XCTAssertEqual(check(Self.usdcTx, Self.usdcHash, intent("5", "USDC", "ana.testnet")).failure, .mismatch("storage deposit"))
        XCTAssertEqual(check(Self.usdcTx, Self.usdcHash, intent("50", "USDC", "bob.testnet")).failure, .mismatch("amount"))
        XCTAssertEqual(check(Self.usdcTx, Self.usdcHash, intent("5", "USDC", "bob.testnet", network: "mainnet")).failure, .mismatch("token contract"))
        XCTAssertEqual(check(Self.nearTx, Self.nearHash, intent("0.5", "NEAR", "ana.testnet"), account: String(repeating: "0", count: 64)).failure, .mismatch("signer"))
        XCTAssertEqual(check(Self.nearTx, Self.usdcHash, intent("0.5", "NEAR", "ana.testnet")).failure, .hashMismatch, "the phone hashes the bytes itself")
        XCTAssertEqual(check("AAAA", Self.nearHash, intent("0.5", "NEAR", "ana.testnet")).failure, .unreadable)
        // An extra action (here a second transfer appended) makes it unreadable.
        var extra = Data(base64Encoded: Self.nearTx)!
        extra[extra.count - 21] = 2
        extra += TestTx.transfer("1")
        XCTAssertEqual(check(extra.base64EncodedString(), Data(SHA256.hash(data: extra)).hex, intent("0.5", "NEAR", "ana.testnet")).failure, .mismatch("actions"))
    }

    func testUnits() {
        XCTAssertEqual(PayTxCheck.units("0.5", decimals: 24), "500000000000000000000000")
        XCTAssertEqual(PayTxCheck.units("5", decimals: 6), "5000000")
        XCTAssertEqual(PayTxCheck.units("2.25", decimals: 6), "2250000")
        XCTAssertNil(PayTxCheck.units("1.1234567", decimals: 6))
        XCTAssertNil(PayTxCheck.units("1e3", decimals: 6))
        XCTAssertNil(PayTxCheck.units("1.", decimals: 6))
    }
}

/// Setup and the network switch.
@MainActor
final class PaySetupModelTests: XCTestCase {
    private func model(_ api: FakePayAPI, _ saved: @escaping (String) -> Void = { _ in }) -> (PaySetupModel, MemoryKeyStorage) {
        let storage = MemoryKeyStorage()
        var pub: String?
        let vault = PayKeyVault(storage: storage, publicKeyHex: { pub }, setPublicKeyHex: { pub = $0 })
        return (PaySetupModel(api: api, vault: vault, keys: MemoryKeys(), saveNetwork: saved), storage)
    }

    func testSetUpMakesTheKeyAndRegistersItsAccount() async throws {
        let api = FakePayAPI()
        let (m, storage) = model(api)
        await m.load()
        XCTAssertNil(m.account)
        await m.setUp()
        let raw = try XCTUnwrap(storage.raw)
        let id = try Curve25519.Signing.PrivateKey(rawRepresentation: raw).publicKey.rawRepresentation.hex
        XCTAssertEqual(m.account, id)
        XCTAssertEqual(api.keys.map(\.network), ["testnet"])
        XCTAssertEqual(PaySetupView.short(id), "\(id.prefix(6))\u{2026}\(id.suffix(6))")
    }

    /// TestFlight 0.2 (3): Home said "Wallet not ready. Pull to try again." for a person who had no wallet yet.
    /// No key: the row offers to create one. One tap makes the key, registers it and shows the funded wallet.
    func testHomeRowOffersCreateThenShowsTheWallet() async {
        let api = FakePayAPI()
        let (m, _) = model(api)
        XCTAssertEqual(m.row, .loading)
        await m.load()
        XCTAssertEqual(m.row, .create)
        await m.setUp()
        guard case .ready(let w) = m.row else { return XCTFail("no wallet: \(m.row)") }
        XCTAssertEqual(w.balances?["NEAR"], "0.2")
        XCTAssertEqual(api.keys.count, 1)
    }

    /// A real failure says what failed, in the server's words, and Retry runs it again.
    func testHomeRowSaysWhatFailedAndRetries() async {
        let api = FakePayAPI()
        api.registerError = APIError.http(502, #"{"error":"could not send test money; try again"}"#)
        let (m, _) = model(api)
        await m.load()
        await m.setUp()
        XCTAssertEqual(m.row, .failed("Could not send test money; try again"))
        api.registerError = nil
        await m.retry()
        guard case .ready = m.row else { return XCTFail("retry did not finish: \(m.row)") }

        api.walletError = URLError(.notConnectedToInternet)
        await m.retry()
        XCTAssertEqual(m.row, .failed("Could not load your wallet. No connection. Try again."))
    }

    func testMainnetSwitchRegistersTheSameKeyAndNeedsTheServerToAllowIt() async {
        let api = FakePayAPI()
        var saved: [String] = []
        let (m, _) = model(api) { saved.append($0) }
        await m.load()
        await m.setUp()
        let id = m.account
        await m.switchTo("mainnet")
        XCTAssertEqual(m.network, "mainnet")
        XCTAssertEqual(saved.last, "mainnet")
        XCTAssertEqual(api.keys.map(\.network), ["testnet", "mainnet"])
        XCTAssertEqual(m.account, id, "one key, the same implicit account on both networks")
        await m.switchTo("testnet")
        XCTAssertEqual(saved.last, "testnet")

        let off = FakePayAPI()
        off.info = PayNetworkInfo(network: "testnet", mainnet_enabled: false, account_id: nil)
        let (m2, _) = model(off)
        await m2.load()
        XCTAssertFalse(m2.mainnetEnabled)
        await m2.switchTo("mainnet")
        XCTAssertEqual(m2.network, "testnet", "no mainnet unless the server has it on")
    }
}

/// Removing the wallet, its warning, and the same key after a new sign-in.
@MainActor
final class WalletRemoveTests: XCTestCase {
    func testRemoveDeletesTheKey() async throws {
        let api = FakePayAPI()
        let vault = PayKeyVault()
        vault.forget()
        defer { vault.forget() }
        let m = PaySetupModel(api: api, vault: vault, keys: MemoryKeys(), saveNetwork: { _ in })
        await m.setUp()
        XCTAssertTrue(m.hasKey)
        XCTAssertTrue(PayKeychain().exists())
        m.removeWallet()
        XCTAssertFalse(m.hasKey)
        XCTAssertNil(m.account)
        XCTAssertFalse(PayKeychain().exists(), "the Keychain item is gone")
        XCTAssertNil(SharedStore.payPublicKey)
    }

    func testTheWarningShowsTheBalance() {
        let w = PayWallet(account_id: "a", status: "ready", network: "testnet", balances: ["NEAR": "1.25", "USDC": "3"])
        let line = WalletWarning.remove(w)
        XCTAssertTrue(line.contains("1.25 NEAR"))
        XCTAssertTrue(line.contains("3 USDC"))
        XCTAssertTrue(line.contains("This cannot be undone; funds are lost without the key."))
        XCTAssertTrue(WalletWarning.remove(nil).contains("could not read"))

        XCTAssertEqual(WalletWarning.onDelete(hasKey: true, wallet: w).map { $0.contains("1.25 NEAR") && $0.contains("cannot be undone") }, true)
        let empty = PayWallet(account_id: "a", status: "ready", network: "testnet", balances: ["NEAR": "0", "USDC": "0"])
        XCTAssertNil(WalletWarning.onDelete(hasKey: true, wallet: empty), "no money, no warning")
        XCTAssertNil(WalletWarning.onDelete(hasKey: false, wallet: w), "no key on this phone, nothing to lose here")
        XCTAssertNotNil(WalletWarning.onDelete(hasKey: true, wallet: nil), "an unread balance still warns")
    }

    /// After logout and a new sign-in the server has no account for this phone yet; opening Pip Pay registers the same key.
    func testTheSameKeyIsRegisteredAgainAfterSignIn() async throws {
        let storage = MemoryKeyStorage()
        var pub: String?
        let vault = PayKeyVault(storage: storage, publicKeyHex: { pub }, setPublicKeyHex: { pub = $0 })
        let pk = try XCTUnwrap(vault.ensure())
        let api = FakePayAPI()
        let m = PaySetupModel(api: api, vault: vault, keys: MemoryKeys(), saveNetwork: { _ in })
        await m.load()
        XCTAssertEqual(api.keys.map(\.key), [pk])
        XCTAssertEqual(m.account, pk)
        XCTAssertNotNil(storage.raw, "no new key was made")
    }
}

extension Result {
    var failure: Failure? { if case .failure(let e) = self { return e }; return nil }
}

/// The approver key lives in the app's own Keychain group; the keyboard reaches only the shared one.
final class ApproverKeychainTests: XCTestCase {
    override func tearDown() { ApproverKeychain().set(nil) }

    func testTheKeyboardsGroupCannotReadTheApproverKey() {
        let keys = ApproverKeychain()
        let before = Keychain.count()
        XCTAssertTrue(keys.set("pap_test_key_never_shared"))
        XCTAssertEqual(keys.get(), "pap_test_key_never_shared")
        XCTAssertNotEqual(ApproverKeychain.group, AppConfig.keychainGroup)
        XCTAssertEqual(Keychain.count(), before, "nothing new in the shared group")
        // What the keyboard can ask for: the same item, in the shared group.
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: ApproverKeychain.service,
                                kSecAttrAccount as String: ApproverKeychain.account, kSecAttrAccessGroup as String: AppConfig.keychainGroup,
                                kSecReturnData as String: true]
        var out: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(q as CFDictionary, &out), errSecItemNotFound)
    }
}
