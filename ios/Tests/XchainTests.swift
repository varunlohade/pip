import CryptoKit
import XCTest
@testable import Pip

/// Server-shaped cross-chain answers (server/src/pay/xchain/routes.ts describe) and the deposit tx an honest server builds.
enum TestXchain {
    static let evm = "0xd8da6bf26964af9d7eed9e10c19b4ae4ff1b9da3"
    static let deposit = String(repeating: "ab", count: 32)
    static let newDeposit = String(repeating: "ef", count: 32)
    static let usdc = PayTxCheck.usdcContracts["mainnet"]!

    static func cardJSON(maxText: String = "5.055", maxUnits: String = "5055000", deposit: String = deposit, refund: String,
                         firstTime: Bool = true, symbolIn: String = "USDC", decimalsIn: Int = 6) -> String {
        """
        {"kind":"xchain","route":"NEAR Intents (1Click)","verified":true,"mode":"exact_out",
         "destination":{"chain":"base","chain_name":"Base","recipient":"\(evm)","asset":"nep141:base-usdc","first_time":\(firstTime)},
         "amount_out":{"units":"5000000","text":"5","symbol":"USDC","chain":"base","decimals":6},
         "min_amount_out":{"units":"5000000","text":"5","symbol":"USDC","chain":"base","decimals":6},
         "max_amount_in":{"units":"\(maxUnits)","text":"\(maxText)","symbol":"\(symbolIn)","chain":"near","decimals":\(decimalsIn)},
         "min_amount_in":{"units":"5000000","text":"5","symbol":"\(symbolIn)","chain":"near","decimals":\(decimalsIn)},
         "fee":{"in_origin":{"units":"55000","text":"0.055","symbol":"\(symbolIn)","chain":"near","decimals":\(decimalsIn)},"usd":"0.054983","bps":"110"},
         "rate":{"text":"1 USDC = 0.989119 USDC","one":"0.989119"},"usd":{"in":"5.05",  "out":"4.99","price_sources":{}},"eta_seconds":22,
         "deposit_address":"\(deposit)","refund_to":"\(refund)","quote_at":"2026-11-14T15:00:00.000Z"}
        """
    }

    static func card(_ json: String) -> XchainCard { try! JSONDecoder().decode(XchainCard.self, from: Data(json.utf8)) }

    static func intent(amount: String = "5.055", token: String = "USDC", deposit: String = deposit) -> PayIntent {
        PayIntent(id: PayIntent.fakeID, amount: amount, token: token, recipient: deposit, status: "pending", network: "mainnet",
                  tx_hash: nil, explorer_url: nil, deep_link: "pip://approve/\(PayIntent.fakeID)", new_recipient: true)
    }

    static func quote(account: String) -> XchainQuote { XchainQuote(card: card(cardJSON(refund: account)), intent: intent()) }

    /// What server/src/pay/xchain/tx.ts buildDeposit makes for a USDC origin with an unregistered deposit account.
    static func usdcDeposit(signer: String, to: String = deposit, units: String = "5055000", contract: String = usdc) -> Data {
        TestTx.tx(signer: signer, receiver: contract, [
            TestTx.call("storage_deposit", #"{"account_id":"\#(to)","registration_only":true}"#, deposit: "1250000000000000000000"),
            TestTx.call("ft_transfer", #"{"receiver_id":"\#(to)","amount":"\#(units)"}"#, deposit: "1"),
        ])
    }
}

final class XchainCardTests: XCTestCase {
    private let me = String(repeating: "cd", count: 32)

    func testCardLinesAreTheServersStringsAsIs() {
        let t = XchainCardText(TestXchain.card(TestXchain.cardJSON(refund: me)))
        XCTAssertEqual(t.gets, "0xd8da\u{2026}9da3 gets exactly 5 USDC on Base")
        XCTAssertEqual(t.pays, "You pay at most 5.055 USDC from your NEAR wallet")
        XCTAssertEqual(t.fee, "Fee 0.055 USDC ($0.054983)")
        XCTAssertEqual(t.rate, "1 USDC = 0.989119 USDC")
        XCTAssertEqual(t.route, "via NEAR Intents")
        XCTAssertEqual(t.eta, "About 22 seconds")
        XCTAssertEqual(t.refund, "Refunds go to cdcdcd\u{2026}cdcd")
        XCTAssertNil(t.blocked)
    }

    /// 24 decimals would not survive a Double; the card never makes one.
    func testLongAmountsAreNotReformatted() {
        let t = XchainCardText(TestXchain.card(TestXchain.cardJSON(maxText: "1.520721912852309794299592", maxUnits: "1520721912852309794299592",
                                                                   refund: me, symbolIn: "wNEAR", decimalsIn: 24)))
        XCTAssertEqual(t.pays, "You pay at most 1.520721912852309794299592 NEAR from your NEAR wallet")
        XCTAssertEqual(XchainCardText.eta(150), "About 3 minutes")
    }

    func testUnverifiedAnswerShowsWhyAndCannotBeApproved() async {
        let json = """
        {"verified":false,"not_verified":["USDC price: only 1 price source answered"],"intent":null,
         "numbers":{"mode":"exact_out","amount_out":{"units":"5000000","text":"5","symbol":"USDC","decimals":6},
           "max_amount_in":{"units":"5055000","text":"5.055","symbol":"USDC","decimals":6},
           "fee":{"in_origin":{"units":"0","text":"0","symbol":"USDC","decimals":6},"usd":null},"rate":{"text":"1 USDC = 0.989119 USDC"},"eta_seconds":22}}
        """
        let q = try! JSONDecoder().decode(XchainQuote.self, from: Data(json.utf8))
        XCTAssertNil(q.intent)
        XCTAssertFalse(q.card.verified)
        let t = XchainCardText(q.card)
        XCTAssertEqual(t.blocked, "Pip could not check this price: USDC price: only 1 price source answered")
        XCTAssertEqual(t.pays, "You pay at most 5.055 USDC from your NEAR wallet")
        XCTAssertEqual(t.fee, "Fee 0 USDC")
        let p = PayPanel(intent: TestXchain.intent(), xchain: q.card)
        XCTAssertFalse(p.canApprove)
    }

    func testARefusalCarriesTheServersReason() {
        let c = TestXchain.card(#"{"error":"the fee is 400 bps, above 300","verified":false,"numbers":null}"#)
        XCTAssertEqual(XchainCardText(c).blocked, "Pip could not check this price: the fee is 400 bps, above 300")
        XCTAssertFalse(c.approvable)
    }

    func testPrefilterOnlyAsksForCrossChainShapes() {
        for t in ["send 5 USDC to \(TestXchain.evm) on base", "send 0.001 btc to bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq",
                  "send 50 xrp to rPEPPER7kfTD9w2To4CQk6UCfuHM9c6GDY tag 123", "pay 10 usdt on tron to TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t",
                  "send 5 USDT to ana.near"] {
            XCTAssertNotNil(XchainDetect.candidate(t), t)
        }
        XCTAssertEqual(XchainDetect.candidate("ok so pay 10 usdt on tron to TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t"),
                       "pay 10 usdt on tron to TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t")
        for t in ["send 5 USDC to ana.testnet", "send 5 USDC to ana.near", "pay 10 bucks to john", "send me the file", "send 5 to 0x12"] {
            XCTAssertNil(XchainDetect.candidate(t), t)
        }
    }

    func testAddressConfirmOffersThreeEndingsWithTheRealOne() {
        for a in [TestXchain.evm, "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t", "ana.testnet", "abcd", "aaaaaaaaaaaaaaaa"] {
            let c = AddressConfirm(a)
            XCTAssertEqual(c.options.count, 3, a)
            XCTAssertEqual(Set(c.options).count, 3, a)
            XCTAssertEqual(c.options.filter { $0 == String(a.suffix(4)) }.count, 1, a)
            XCTAssertFalse(c.confirmed)
        }
    }
}

final class XchainTxCheckTests: XCTestCase {
    private let me = String(repeating: "cd", count: 32)

    private func check(_ tx: Data, intent: PayIntent = TestXchain.intent(), card: XchainCard? = nil) -> PayTxCheck.Refusal? {
        let c = card ?? TestXchain.card(TestXchain.cardJSON(refund: me))
        return PayTxCheck.check(TestTx.unsigned(intent.id, tx), intent: intent, account: me, xchain: c).failure
    }

    func testHonestDepositsPass() throws {
        let ok = PayTxCheck.check(TestTx.unsigned(PayIntent.fakeID, TestXchain.usdcDeposit(signer: me)), intent: TestXchain.intent(), account: me,
                                  xchain: TestXchain.card(TestXchain.cardJSON(refund: me)))
        XCTAssertEqual(try ok.get().seen, .init(signer: me, receiver: TestXchain.deposit, amount: "5055000", token: "USDC"))
        // NEAR origin: register the signer and the deposit account on wrap.near, wrap the exact amount, then ft_transfer.
        let units = "1520721912852309794299592"
        let wrap = TestTx.tx(signer: me, receiver: "wrap.near", [
            TestTx.call("storage_deposit", #"{"account_id":"\#(me)","registration_only":true}"#, deposit: "1250000000000000000000"),
            TestTx.call("storage_deposit", #"{"account_id":"\#(TestXchain.deposit)","registration_only":true}"#, deposit: "1250000000000000000000"),
            TestTx.call("near_deposit", "{}", deposit: units),
            TestTx.call("ft_transfer", #"{"receiver_id":"\#(TestXchain.deposit)","amount":"\#(units)"}"#, deposit: "1"),
        ])
        let nearCard = TestXchain.card(TestXchain.cardJSON(maxText: "1.520721912852309794299592", maxUnits: units, refund: me, symbolIn: "wNEAR", decimalsIn: 24))
        XCTAssertNil(check(wrap, intent: TestXchain.intent(amount: "1.520721912852309794299592", token: "NEAR"), card: nearCard))
        // USDT goes to the Tether contract and nowhere else.
        XCTAssertNil(check(TestXchain.usdcDeposit(signer: me, contract: "usdt.tether-token.near"), intent: TestXchain.intent(token: "USDT")))
    }

    func testAnyOtherDepositIsRefused() {
        let me = self.me
        XCTAssertEqual(check(TestXchain.usdcDeposit(signer: me, contract: "evil.near")), .mismatch("token contract"))
        XCTAssertEqual(check(TestXchain.usdcDeposit(signer: me, to: TestXchain.newDeposit)), .mismatch("actions"), "storage for another account")
        XCTAssertEqual(check(TestTx.tx(signer: me, receiver: TestXchain.usdc, [
            TestTx.call("ft_transfer", #"{"receiver_id":"\#(TestXchain.newDeposit)","amount":"5055000"}"#, deposit: "1")])), .mismatch("receiver"))
        XCTAssertEqual(check(TestXchain.usdcDeposit(signer: me, units: "5055001")), .mismatch("amount"))
        XCTAssertEqual(check(TestXchain.usdcDeposit(signer: me) , intent: TestXchain.intent(amount: "5.06")), .mismatch("amount"), "intent and card disagree")
        XCTAssertEqual(check(TestXchain.usdcDeposit(signer: me), intent: TestXchain.intent(deposit: TestXchain.newDeposit)), .mismatch("deposit address"))
        var testnet = TestXchain.intent()
        testnet = PayIntent(id: testnet.id, amount: testnet.amount, token: "USDC", recipient: testnet.recipient, status: "pending", network: "testnet",
                            tx_hash: nil, explorer_url: nil, deep_link: "")
        XCTAssertEqual(check(TestXchain.usdcDeposit(signer: me), intent: testnet), .mismatch("network"))
        // A storage_deposit that attaches more than 0.01 NEAR.
        XCTAssertEqual(check(TestTx.tx(signer: me, receiver: TestXchain.usdc, [
            TestTx.call("storage_deposit", #"{"account_id":"\#(TestXchain.deposit)","registration_only":true}"#, deposit: "20000000000000000000000"),
            TestTx.call("ft_transfer", #"{"receiver_id":"\#(TestXchain.deposit)","amount":"5055000"}"#, deposit: "1")])), .mismatch("actions"))
        // NEAR origin without the wrap, or wrapping a different amount.
        let units = "1520721912852309794299592"
        let nearCard = TestXchain.card(TestXchain.cardJSON(maxText: "1.520721912852309794299592", maxUnits: units, refund: me, symbolIn: "wNEAR", decimalsIn: 24))
        let nearIntent = TestXchain.intent(amount: "1.520721912852309794299592", token: "NEAR")
        XCTAssertEqual(check(TestTx.tx(signer: me, receiver: "wrap.near", [
            TestTx.call("ft_transfer", #"{"receiver_id":"\#(TestXchain.deposit)","amount":"\#(units)"}"#, deposit: "1")]), intent: nearIntent, card: nearCard), .mismatch("wrap"))
        XCTAssertEqual(check(TestTx.tx(signer: me, receiver: "wrap.near", [
            TestTx.call("near_deposit", "{}", deposit: "2" + units.dropFirst()),
            TestTx.call("ft_transfer", #"{"receiver_id":"\#(TestXchain.deposit)","amount":"\#(units)"}"#, deposit: "1")]), intent: nearIntent, card: nearCard), .mismatch("wrap"))
        // An extra plain transfer after the deposit.
        XCTAssertEqual(check(TestTx.tx(signer: me, receiver: TestXchain.usdc, [
            TestTx.call("ft_transfer", #"{"receiver_id":"\#(TestXchain.deposit)","amount":"5055000"}"#, deposit: "1"), TestTx.transfer("1")])), .mismatch("actions"))
        // An unverified card is never signed for.
        var unverified = TestXchain.card(TestXchain.cardJSON(refund: me))
        unverified.verified = false
        XCTAssertEqual(check(TestXchain.usdcDeposit(signer: me), card: unverified), .mismatch("card"))
    }
}

@MainActor
final class KeyboardXchainTests: XCTestCase {
    private var host: FakeHost!
    private var api: FakeAPI!
    private var signer: FakeSigner!
    private var model: KeyboardModel!
    private var savedNetwork: String?

    override func setUp() async throws {
        savedNetwork = SharedStore.payNetwork
        SharedStore.payNetwork = "mainnet"
        KeyboardModel.swapPollEvery = .milliseconds(1)
        host = FakeHost()
        api = FakeAPI()
        signer = FakeSigner()
        api.account = signer.accountID()!
        api.unsignedXchain = { [api] i in TestTx.unsigned(i.id, TestXchain.usdcDeposit(signer: api!.account)) }
        model = KeyboardModel(deps: .fake(api: api, store: FakeStore(), signer: signer))
        model.host = host
        model.keyboardAppeared()
    }

    override func tearDown() async throws {
        SharedStore.payNetwork = savedNetwork
        KeyboardModel.swapPollEvery = .seconds(3)
    }

    private func set(_ text: String) {
        host.text = text
        model.textChanged()
    }

    private func until(_ what: String, timeout: Int = 3000, _ cond: () -> Bool) async {
        for _ in 0..<timeout where !cond() { await Task.yield(); try? await Task.sleep(for: .milliseconds(1)) }
        XCTAssertTrue(cond(), "timed out waiting for \(what)")
    }

    private func card() async {
        set("send 5 USDC to \(TestXchain.evm) on base")
        await until("the chip") { model.payItem?.detail == "Review" }
        model.perform(.pay)
        await until("the card") { model.payPanel != nil }
    }

    private func confirmEnd() {
        model.pickAddressEnd(String(TestXchain.evm.suffix(4)))
    }

    func testChipComesFromTheServersParse() async {
        set("send 5 USDC to \(TestXchain.evm) on base")
        XCTAssertNil(model.payItem, "no chip until the server has read it")
        await until("the chip") { model.payItem?.detail == "Review" }
        XCTAssertEqual(api.parsed, ["send 5 USDC to \(TestXchain.evm) on base"])
        XCTAssertEqual(model.payItem?.title, "Send 5 USDC to 0xd8da\u{2026}9da3")
        XCTAssertFalse(api.calls.contains("route"))
    }

    func testServerReasonShowsWhenItCannotPay() async {
        api.parseReply = XchainParsed(valid: false, reason: "not an address Pip knows")
        set("send 0.001 btc to bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq")
        await until("the reason") { model.payItem?.title == "not an address Pip knows" }
        XCTAssertNil(model.payItem?.action)
    }

    func testTestnetAsksTheServerForALivePreview() async {
        SharedStore.payNetwork = "testnet"
        XCTAssertEqual(PayNetwork.name, "testnet")
        set("pay 10 usdt on tron to TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t")
        await until("the chip") { model.payItem?.detail == "Review" }
        XCTAssertEqual(api.parsed, ["pay 10 usdt on tron to TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t"])
    }

    func testFirstTimeAddressNeedsItsEndingThenOneFaceIDThenSwapStatus() async throws {
        api.statusReplies = [XchainStatus(status: "swapping"),
                             XchainStatus(status: "delivered", delivered_tx: [.init(hash: "0xfa4e", explorerUrl: "https://basescan.org/tx/0xfa4e")])]
        await card()
        let p = try XCTUnwrap(model.payPanel)
        XCTAssertEqual(p.xchain?.destination?.chain_name, "Base")
        XCTAssertEqual(p.confirm?.address, TestXchain.evm, "the destination is confirmed, not the deposit account")
        XCTAssertFalse(p.canApprove)
        confirmEnd()
        XCTAssertTrue(model.payPanel!.canApprove)
        model.approvePayInKeyboard()
        await until("swapping") { model.payPanel?.swap != nil }
        XCTAssertEqual(signer.asks, 1)
        XCTAssertEqual(signer.prompts, ["Send 5 USDC on Base to 0xd8da\u{2026}9da3"])
        let proof = try XCTUnwrap(api.proofs.first ?? nil)
        XCTAssertTrue(signer.key.publicKey.isValidSignature(proof, for: PayApproval.proofHash(TestXchain.intent())))
        let s = try XCTUnwrap(api.submitted.first)
        XCTAssertEqual(s.hash, Data(SHA256.hash(data: TestXchain.usdcDeposit(signer: api.account))))
        XCTAssertTrue(signer.key.publicKey.isValidSignature(s.signature, for: s.hash))
        await until("delivered") { model.payPanel?.swap == .delivered(url: "https://basescan.org/tx/0xfa4e") }
        XCTAssertEqual(PayPanelBar.title(model.payPanel!), "Sent on Base \u{2713}")
        model.insertKeyboardSent()
        XCTAssertTrue(host.text.hasSuffix("Sent you 5 USDC on Base \u{2713} https://basescan.org/tx/0xfa4e"), host.text)
    }

    func testKnownAddressSkipsTheEndingCheck() async {
        api.quoteReply = XchainQuote(card: TestXchain.card(TestXchain.cardJSON(refund: api.account, firstTime: false)), intent: TestXchain.intent())
        await card()
        XCTAssertNil(model.payPanel?.confirm)
        XCTAssertTrue(model.payPanel!.canApprove)
    }

    func testRefundIsSaidPlainly() async {
        api.statusReplies = [XchainStatus(status: "refunded", refund_reason: "the price moved")]
        await card()
        confirmEnd()
        model.approvePayInKeyboard()
        await until("refunded") { model.payPanel?.swap == .refunded("the price moved") }
        XCTAssertEqual(PayPanelBar.title(model.payPanel!), "Refunded. The money is back in your NEAR wallet. (the price moved)")
    }

    func testUnverifiedQuoteCannotBeApproved() async {
        var c = TestXchain.card(TestXchain.cardJSON(refund: api.account))
        c.verified = false
        c.notVerified = ["USDC price: only 1 price source answered"]
        api.quoteReply = XchainQuote(card: c, intent: nil)
        await card()
        confirmEnd()
        XCTAssertFalse(model.payPanel!.canApprove)
        model.approvePayInKeyboard()
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(signer.asks, 0)
        XCTAssertEqual(api.calls.filter { $0 == "unsigned" }.count, 0)
    }

    /// The price moved: /unsigned re-quotes onto a new deposit account. The new card shows, Face ID runs again, and the phone
    /// checks the transaction against the NEW card.
    func testRequoteShowsTheNewCardAndNeedsFaceIDAgain() async throws {
        let account = api.account
        let fresh = TestXchain.cardJSON(maxText: "5.06", maxUnits: "5060000", deposit: TestXchain.newDeposit, refund: account)
        api.unsignedXchain = { i in
            var u = TestTx.unsigned(i.id, TestXchain.usdcDeposit(signer: account, to: TestXchain.newDeposit, units: "5060000"))
            u.requoted = true
            u.xchain = TestXchain.card(fresh)
            u.amount = "5.06"
            u.token = "USDC"
            u.recipient = TestXchain.newDeposit
            return u
        }
        await card()
        confirmEnd()
        model.approvePayInKeyboard()
        await until("the new card") { model.payPanel?.requoted == true && model.payPanel?.phase == .ready }
        XCTAssertEqual(PayPanelBar.title(model.payPanel!), "Price updated")
        XCTAssertEqual(XchainCardText(model.payPanel!.xchain!).pays, "You pay at most 5.06 USDC from your NEAR wallet")
        XCTAssertEqual(model.payPanel?.intent.recipient, TestXchain.newDeposit)
        XCTAssertEqual(api.submitted.count, 0, "nothing is signed on the old Face ID")
        XCTAssertEqual(signer.asks, 1)
        model.approvePayInKeyboard()
        await until("sent") { model.payPanel?.phase == .sent }
        XCTAssertEqual(signer.asks, 2, "Face ID again for the new price")
        XCTAssertEqual(api.calls.filter { $0 == "unsigned" }.count, 1, "the re-quoted bytes are used, not rebuilt")
        let s = try XCTUnwrap(api.submitted.first)
        XCTAssertEqual(s.hash, Data(SHA256.hash(data: TestXchain.usdcDeposit(signer: account, to: TestXchain.newDeposit, units: "5060000"))))
    }

    func testRequoteWhoseTxStillPaysTheOldDepositIsRefused() async {
        let account = api.account
        api.unsignedXchain = { i in
            var u = TestTx.unsigned(i.id, TestXchain.usdcDeposit(signer: account))
            u.requoted = true
            u.xchain = TestXchain.card(TestXchain.cardJSON(maxText: "5.06", maxUnits: "5060000", deposit: TestXchain.newDeposit, refund: account))
            u.amount = "5.06"
            u.recipient = TestXchain.newDeposit
            return u
        }
        await card()
        confirmEnd()
        model.approvePayInKeyboard()
        await until("the new card") { model.payPanel?.requoted == true && model.payPanel?.phase == .ready }
        model.approvePayInKeyboard()
        await until("refused") { model.payPanel?.phase == .failed(PayTxCheck.refusedLine) }
        XCTAssertEqual(api.submitted.count, 0)
    }
}
