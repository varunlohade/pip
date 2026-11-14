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
    private var auth: FakeAuth!
    private var model: KeyboardModel!

    override func setUp() async throws {
        host = FakeHost()
        api = FakeAPI()
        store = FakeStore()
        auth = FakeAuth()
        model = KeyboardModel(deps: .fake(api: api, store: store, auth: auth))
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

    func testTheChipShowsFirstAndSendsNothingToSuggest() async {
        set("send 5 USDC to ana.near")
        let item = model.barItems.first
        XCTAssertEqual(item?.id, "pay")
        XCTAssertEqual(item?.title, "Send 5 USDC to ana.testnet")
        XCTAssertFalse(model.showsWordSlots)
        for _ in 0..<50 { await Task.yield() }
        XCTAssertFalse(api.calls.contains("suggest"))
    }

    func testKnownRecipientWithinLimitApprovesInTheKeyboardAfterFaceID() async {
        set("send 5 USDC to ana.near")
        model.perform(.pay)
        await until("the card") { model.payPanel != nil }
        XCTAssertEqual(api.proposed.first?.recipient, "ana.testnet")
        XCTAssertEqual(store.payPending, PayIntent.fakeID)
        XCTAssertEqual(host.opened, [], "a keyboard send does not open the app")
        model.approvePayInKeyboard()
        await until("sent") { model.payPanel?.phase == .sent }
        XCTAssertEqual(auth.asks, 1)
        XCTAssertEqual(api.keyboardApproved.map(\.key), [store.payKeyboardKey!])
        XCTAssertEqual(model.payPanel?.leftAfter, "15")
        XCTAssertNil(store.payPending)
        model.insertKeyboardSent()
        XCTAssertEqual(host.text, "Sent you 5 USDC \u{2713} https://testnet.nearblocks.io/txns/7Hq2Xb9TfE3mNwq8RkLz5VdYc1pA6sGh1uJkP4")
        XCTAssertNil(model.payPanel)
    }

    func testTheSameTypedAgainOffersTheChipAgain() async {
        api.keyboardCheck = .init(ok: false, reason: "new_recipient", left: "20", paid_before: 0)
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
        auth.answer = .denied
        set("send 5 USDC to ana.testnet")
        model.perform(.pay)
        await until("the card") { model.payPanel != nil }
        model.approvePayInKeyboard()
        await until("the note") { model.payPanel?.note != nil }
        XCTAssertEqual(model.payPanel?.phase, .ready)
        XCTAssertEqual(api.keyboardApproved.count, 0)
    }

    func testNoFaceIDInTheKeyboardOpensTheApp() async {
        auth.answer = .unavailable
        set("send 5 USDC to ana.testnet")
        model.perform(.pay)
        await until("the card") { model.payPanel != nil }
        model.approvePayInKeyboard()
        await until("the app") { !host.opened.isEmpty }
        XCTAssertEqual(host.opened.first?.absoluteString, "pip://approve/\(PayIntent.fakeID)")
        XCTAssertEqual(api.keyboardApproved.count, 0)
        XCTAssertNil(model.payPanel)
    }

    func testNewRecipientOpensTheApp() async {
        api.keyboardCheck = .init(ok: false, reason: "new_recipient", left: "20", paid_before: 0)
        set("send 5 USDC to ana.testnet")
        model.perform(.pay)
        await until("the bar line") { model.bar == .done("Open Pip to approve") }
        XCTAssertNil(model.payPanel)
        XCTAssertEqual(host.opened.count, 1)
        XCTAssertEqual(store.payPending, PayIntent.fakeID, "the app finds it when opened by hand")
    }

    func testNoKeyboardKeyOpensTheApp() async {
        store.payKeyboardKey = nil
        host.canOpen = true
        set("send 5 USDC to ana.testnet")
        model.perform(.pay)
        await until("the bar line") { model.bar == .done("Opening Pip\u{2026}") }
        XCTAssertNil(model.payPanel)
    }

    func testServerRefusalOpensTheApp() async {
        api.keyboardApproveError = APIError.http(403, #"{"error":"over the keyboard limit: approve in the Pip app","needs_app":true}"#)
        set("send 5 USDC to ana.testnet")
        model.perform(.pay)
        await until("the card") { model.payPanel != nil }
        model.approvePayInKeyboard()
        await until("the app") { !host.opened.isEmpty }
        XCTAssertNil(model.payPanel)
    }

    func testRejectTellsTheServerAndSendsNothing() async {
        set("send 5 USDC to ana.testnet")
        model.perform(.pay)
        await until("the card") { model.payPanel != nil }
        model.rejectPayInKeyboard()
        await until("reject") { api.rejected.count == 1 }
        XCTAssertNil(model.payPanel)
        XCTAssertEqual(api.keyboardApproved.count, 0)
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

/// The app's approval card: Face ID first, then the approver key.
@MainActor
final class ApprovalModelTests: XCTestCase {
    final class FakePayAPI: PayAPI {
        var intent = PayIntent.fake(PayDraft(amount: "5", token: "USDC", recipient: "ana.testnet", trigger: ""))
        private(set) var approvedWith: [String] = []
        private(set) var registered = 0
        func payIntent(_ id: String) async throws -> PayIntent { intent }
        func approvePay(_ i: PayIntent, approverKey: String) async throws -> PayIntent {
            approvedWith.append(approverKey)
            return PayIntent.fake(PayDraft(amount: i.amount, token: i.token, recipient: i.recipient, trigger: ""), status: "sent")
        }
        func rejectPay(_ id: String) async throws -> PayIntent { intent }
        func registerApprover(current: String?) async throws -> String { registered += 1; return "pap_new_key" }
        func payWallet() async throws -> PayWallet { PayWallet(account_id: "pip-1.pipfund.testnet", status: "ready", network: "testnet", balances: ["USDC": "42.1"]) }
        func aiAttestation() async throws -> AIAttestation { AIAttestation(isPrivate: true, attested: true) }
    }

    final class MemoryKeys: ApproverKeys {
        var key: String?
        func get() -> String? { key }
        func set(_ key: String?) -> Bool { self.key = key; return true }
    }

    func testApproveNeedsFaceIDThenUsesTheApproverKey() async {
        let api = FakePayAPI(), auth = FakeAuth(), keys = MemoryKeys()
        var sent: [PaySent] = []
        let m = ApprovalModel(id: PayIntent.fakeID, api: api, auth: auth, keys: keys, recordSent: { sent.append($0) })
        await m.load()
        XCTAssertEqual(m.phase, .ready)
        XCTAssertEqual(m.mark, .verified)

        auth.answer = .denied
        await m.approve()
        XCTAssertEqual(api.approvedWith, [], "no Face ID, no call")
        XCTAssertEqual(m.note, "Not approved. Nothing was sent.")

        auth.answer = .approved
        await m.approve()
        XCTAssertEqual(api.registered, 1, "first approve makes the key")
        XCTAssertEqual(api.approvedWith, ["pap_new_key"])
        XCTAssertEqual(m.phase, .sent)
        XCTAssertEqual(sent.first?.label, "Sent 5 USDC to ana.testnet")
    }

    func testDeepLinkTakesOnlyAnIntentID() {
        XCTAssertEqual(PayApprovalRequest(url: URL(string: "pip://approve/\(PayIntent.fakeID)")!)?.id, PayIntent.fakeID)
        XCTAssertNil(PayApprovalRequest(url: URL(string: "pip://approve/../wallet")!))
        XCTAssertNil(PayApprovalRequest(url: URL(string: "pip://approve/\(PayIntent.fakeID)/x")!))
        XCTAssertNil(PayApprovalRequest(url: URL(string: "https://approve/\(PayIntent.fakeID)")!))
    }
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
