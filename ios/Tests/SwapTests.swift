import XCTest
@testable import Pip

/// Server-shaped swap, preview and request answers (server/src/pay/xchain/routes.ts).
extension TestXchain {
    static func swapJSON(preview: Bool = false, action: String? = nil, deposit: String? = deposit) -> String {
        """
        {"kind":"xchain","swap":true,"route":"NEAR Intents (1Click)","verified":true,"mode":"exact_in","slippage_bps":100,
         "route_path":["NEAR in your NEAR wallet","NEAR Intents solvers","USDC on NEAR"],
         \(preview ? #""preview":true,"preview_reason":"balance","intent":null,"# : "")
         \(action.map { #""action":"\#($0)","# } ?? "")
         "destination":{"chain":"near","chain_name":"NEAR","recipient":"\(String(repeating: "cd", count: 32))","first_time":false},
         "numbers":{"mode":"exact_in",
           "amount_out":{"units":"3091943","text":"3.091943","symbol":"USDC","chain":"near","decimals":6},
           "min_amount_out":{"units":"3061023","text":"3.061023","symbol":"USDC","chain":"near","decimals":6},
           "max_amount_in":{"units":"1000000000000000000000000","text":"1","symbol":"wNEAR","chain":"near","decimals":24},
           "fee":{"in_origin":{"units":"16000000000000000000000","text":"0.016","symbol":"wNEAR","chain":"near","decimals":24},"usd":"0.050101","bps":"162"},
           "rate":{"text":"1 wNEAR = 3.091943 USDC","one":"3.091943"},"eta_seconds":22}
         \(deposit.map { #","deposit_address":"\#($0)""# } ?? "")}
        """
    }

    static func request(live: Bool = true, kind: String = "request") -> RequestCard {
        let json = """
        {"kind":"\(kind)","verified":true,"slippage_bps":100,"route_path":["USDC on Base","NEAR Intents solvers","USDC in your Pip wallet"],
         "origin":{"chain":"base","chain_name":"Base"},
         "numbers":{"mode":"exact_in",
           "amount_out":{"units":"4995554","text":"4.995554","symbol":"USDC","chain":"near","decimals":6},
           "min_amount_out":{"units":"4945598","text":"4.945598","symbol":"USDC","chain":"near","decimals":6},
           "max_amount_in":{"units":"5000000","text":"5","symbol":"USDC","chain":"base","decimals":6},
           "fee":{"in_origin":{"units":"54000","text":"0.054","symbol":"USDC","chain":"base","decimals":6},"usd":"0.054383","bps":"109"},
           "rate":{"text":"1 USDC = 0.99911 USDC","one":"0.99911"},"eta_seconds":35},
         "refund_note":"If the payment fails or comes in after the deadline, NEAR Intents refunds it to your Pip account's NEAR Intents balance, not to the payer.",
         \(live ? #""deposit_address":"0x7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a","valid_until":"2026-11-14T15:45:00.000Z","request":{"id":"\#(String(repeating: "12", count: 16))","status":"waiting_for_payment"}"#
                : #""preview":true,"action":"Switch to Mainnet to get a real deposit address","request":null"#)}
        """
        return try! JSONDecoder().decode(RequestCard.self, from: Data(json.utf8))
    }
}

@MainActor
final class SwapCardTests: XCTestCase {
    func testSwapLinesSlippageAndIntentsRoute() {
        let c = TestXchain.card(TestXchain.swapJSON())
        let t = XchainCardText(c)
        XCTAssertEqual(t.gets, "You get at least 3.061023 USDC")
        XCTAssertEqual(t.pays, "You swap exactly 1 NEAR from your NEAR wallet")
        XCTAssertEqual(t.slippage, "Slippage: up to 1%")
        XCTAssertEqual(t.intents, "Routed by NEAR Intents solvers")
        XCTAssertEqual(t.path, "NEAR in your NEAR wallet \u{2192} NEAR Intents solvers \u{2192} USDC on NEAR")
        XCTAssertNil(t.previewTag)
        XCTAssertNil(t.blocked)
        XCTAssertTrue(c.approvable)
        XCTAssertFalse(c.firstTime, "a swap goes to the owner: no address to confirm")
        XCTAssertEqual(XchainCardText.percent(50), "0.5%")
        XCTAssertEqual(XchainCardText.percent(125), "1.25%")
        XCTAssertEqual(XchainCardText.percent(105), "1.05%")
    }

    func testPreviewShowsTheNumbersAndWhatIsMissingButCannotBeApproved() {
        let c = TestXchain.card(TestXchain.swapJSON(preview: true, action: "Need 0.8 more NEAR", deposit: nil))
        let t = XchainCardText(c)
        XCTAssertEqual(t.previewTag, "Live NEAR Intents quote \u{00B7} preview")
        XCTAssertEqual(t.gets, "You get at least 3.061023 USDC")
        XCTAssertEqual(t.blocked, "Need 0.8 more NEAR")
        XCTAssertFalse(c.approvable)
        // Even with a deposit address, a preview is never approvable.
        XCTAssertFalse(TestXchain.card(TestXchain.swapJSON(preview: true, action: "x")).approvable)
        let p = PayPanel(intent: TestXchain.intent(), xchain: c)
        XCTAssertFalse(p.canApprove)
        XCTAssertEqual(PayPanelBar.title(p), "Live NEAR Intents quote \u{00B7} preview")
    }

    func testRequestLineAndStatusWords() {
        let r = TestXchain.request()
        XCTAssertTrue(r.live)
        let t = RequestText(r)
        XCTAssertEqual(t.title, "Request 5 USDC on Base")
        XCTAssertEqual(t.pays, "They pay exactly 5 USDC on Base")
        XCTAssertEqual(t.gets, "You get at least 4.945598 USDC in your Pip wallet")
        XCTAssertNil(t.blocked)
        XCTAssertEqual(RequestText.chatLine(r, timeZone: TimeZone(identifier: "UTC")!),
                       "Pay 5 USDC on Base to 0x7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a (via NEAR Intents, arrives in my Pip wallet, valid until 3:45 PM)")
        XCTAssertEqual(RequestText.status(RequestStatus(status: "received", received: .init(text: "4.99", symbol: "USDC"))), "Received 4.99 USDC \u{2713}")
        XCTAssertEqual(RequestText.status(RequestStatus(status: "waiting_for_payment")), "Waiting for payment\u{2026}")
        XCTAssertTrue(RequestText.status(RequestStatus(status: "refunded")).hasPrefix("Refunded to your NEAR Intents balance"))
        let preview = TestXchain.request(live: false)
        XCTAssertFalse(preview.live)
        XCTAssertNil(RequestText.chatLine(preview), "no address, nothing to share")
        XCTAssertEqual(RequestText(preview).blocked, "Switch to Mainnet to get a real deposit address")
        XCTAssertEqual(RequestText(TestXchain.request(kind: "topup")).title, "Top up 5 USDC from Base")
    }

    func testPrefilterFindsSwapsRequestsAndTopUps() {
        for t in ["swap 1 near to usdc", "convert 0.5 near into usdc", "swap 10 usdc to eth on base", "request 5 usdc on base",
                  "ask ana for 5 usdc on base", "top up my pip from base", "charge raj 12 usdt on tron", "swap $5 usdc for usdt"] {
            XCTAssertNotNil(XchainDetect.candidate(t), t)
        }
        XCTAssertEqual(XchainDetect.candidate("ok swap 1 near to usdc"), "swap 1 near to usdc")
        for t in ["let us swap seats", "request a refund", "top up the coffee", "convert this pdf to word"] {
            XCTAssertNil(XchainDetect.candidate(t), t)
        }
    }
}

@MainActor
final class KeyboardSwapTests: XCTestCase {
    private var host: FakeHost!
    private var api: FakeAPI!
    private var signer: FakeSigner!
    private var pasteboard: FakePasteboard!
    private var model: KeyboardModel!
    private var savedNetwork: String?

    override func setUp() async throws {
        savedNetwork = SharedStore.payNetwork
        SharedStore.payNetwork = "testnet"
        KeyboardModel.swapPollEvery = .milliseconds(1)
        host = FakeHost()
        api = FakeAPI()
        signer = FakeSigner()
        pasteboard = FakePasteboard()
        api.account = signer.accountID()!
        model = KeyboardModel(deps: .fake(api: api, store: FakeStore(), pasteboard: pasteboard, signer: signer))
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

    /// Testnet: "swap 1 near to usdc" gets a live preview card. Approve is off and no signing path is reachable.
    func testPreviewSwapOnTestnetHasNoSigningPath() async throws {
        api.parseReply = XchainParsed(valid: true, kind: "swap", amount: "1", token: "USDC", chain: "near", from: "NEAR")
        api.quoteReply = XchainQuote(card: TestXchain.card(TestXchain.swapJSON(preview: true, action: "Switch to Mainnet and add 1 NEAR to send", deposit: nil)), intent: nil)
        set("swap 1 near to usdc")
        await until("the swap chip") { model.payItem?.title == "Swap 1 NEAR to USDC" }
        model.perform(.pay)
        await until("the card") { model.payPanel != nil }
        let p = try XCTUnwrap(model.payPanel)
        XCTAssertEqual(api.quoted.first?.kind, "swap")
        XCTAssertTrue(p.xchain?.preview == true)
        XCTAssertFalse(p.canApprove)
        XCTAssertNil(p.confirm)
        XCTAssertEqual(XchainCardText(p.xchain!).blocked, "Switch to Mainnet and add 1 NEAR to send")
        model.approvePayInKeyboard()
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(signer.asks, 0, "no Face ID")
        XCTAssertFalse(api.calls.contains("unsigned"))
        XCTAssertFalse(api.calls.contains("submit"))
        model.rejectPayInKeyboard()
        XCTAssertNil(model.payPanel)
        XCTAssertFalse(api.calls.contains("reject"), "a preview has nothing to decline on the server")
    }

    /// Mainnet: a real swap card is approvable with one Face ID; the prompt says what is swapped.
    func testRealSwapAsksFaceIDWithASwapPrompt() async throws {
        SharedStore.payNetwork = "mainnet"
        api.parseReply = XchainParsed(valid: true, kind: "swap", amount: "1", token: "USDC", chain: "near", from: "NEAR")
        api.quoteReply = XchainQuote(card: TestXchain.card(TestXchain.swapJSON()), intent: TestXchain.intent(amount: "1", token: "NEAR"))
        set("swap 1 near to usdc")
        await until("the swap chip") { model.payItem?.detail == "Review" }
        model.perform(.pay)
        await until("the card") { model.payPanel != nil }
        XCTAssertTrue(model.payPanel!.canApprove)
        XCTAssertEqual(model.payPanel!.prompt, "Swap 1 NEAR for at least 3.061023 USDC")
        XCTAssertEqual(PayPanelBar.title(model.payPanel!), "Swap 1 NEAR to USDC")
    }

    /// "request 5 usdc" with no chain asks which chain; a chip adds it; the card's Insert types the request; Pip watches it land.
    func testRequestAsksTheChainThenInsertsTheLineAndShowsReceived() async throws {
        SharedStore.payNetwork = "mainnet"
        api.parseReply = XchainParsed(valid: false, kind: "request", reason: "Which chain will they pay from?", needs: "chain")
        set("request 5 usdc")
        await until("which chain") { model.payItem?.title == "Which chain will they pay from?" }
        guard case .chainChoice(_, let chains, _) = model.xchainOffer else { return XCTFail("no chain chips") }
        XCTAssertEqual(chains.first?.words, "base")
        api.parseReply = XchainParsed(valid: true, kind: "request", amount: "5", token: "USDC", chain: "base")
        model.pickChain("base")
        XCTAssertEqual(host.text, "request 5 usdc on base")
        await until("the request chip") { model.payItem?.title == "Request 5 USDC on Base" }
        api.requestStatusReplies = [RequestStatus(status: "waiting_for_payment"), RequestStatus(status: "received", received: .init(text: "4.994", symbol: "USDC"))]
        model.perform(.pay)
        await until("the card") { model.payPanel?.request != nil }
        XCTAssertFalse(model.payPanel!.canApprove, "nothing to approve: Pip moves no money")
        XCTAssertEqual(PayPanelBar.title(model.payPanel!), "Request 5 USDC on Base")
        model.insertKeyboardSent()
        XCTAssertTrue(host.text.hasPrefix("Pay 5 USDC on Base to 0x7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a (via NEAR Intents, arrives in my Pip wallet, valid until "), host.text)
        XCTAssertFalse(host.text.contains("request 5 usdc"), "the typed ask is replaced by the request")
        await until("received") { model.payPanel?.requestStatus?.status == "received" }
        XCTAssertEqual(RequestText.status(model.payPanel!.requestStatus!), "Received 4.994 USDC \u{2713}")
        XCTAssertEqual(signer.asks, 0)
        XCTAssertFalse(api.calls.contains("unsigned"))
    }

    /// A top-up copies the deposit address instead of typing in the chat.
    func testTopUpCopiesTheAddress() async throws {
        api.parseReply = XchainParsed(valid: true, kind: "topup", amount: "5", token: "USDC", chain: "base")
        api.requestReply = TestXchain.request(kind: "topup")
        set("top up my pip with 5 usdc from base")
        await until("the top-up chip") { model.payItem?.title == "Top up 5 USDC from Base" }
        model.perform(.pay)
        await until("the card") { model.payPanel?.request != nil }
        model.insertKeyboardSent()
        XCTAssertEqual(pasteboard.string, "0x7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a")
        XCTAssertEqual(host.text, "top up my pip with 5 usdc from base")
    }

    /// Testnet request: a preview with no address; Insert stays off.
    func testRequestPreviewHasNoAddressToShare() async throws {
        api.parseReply = XchainParsed(valid: true, kind: "request", amount: "5", token: "USDC", chain: "base")
        api.requestReply = TestXchain.request(live: false)
        set("request 5 usdc on base")
        await until("the chip") { model.payItem?.detail == "Review" }
        model.perform(.pay)
        await until("the card") { model.payPanel?.request != nil }
        let before = host.text
        model.insertKeyboardSent()
        XCTAssertEqual(host.text, before, "nothing to insert from a preview")
        XCTAssertFalse(api.calls.contains("rstatus"))
    }
}
