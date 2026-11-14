import XCTest
@testable import Pip

/// TestFlight 0.4 (5) fixes: typo-tolerant explain, the Draw it chip, the jev router, the secret filter,
/// crypto words autocorrect leaves alone, "$0.02 USDT" payments, and Fix with no confirmation line.
final class ExplainTypoTests: XCTestCase {
    private func topic(_ text: String, _ subject: String, line: UInt = #line) {
        let a = Explain.detect(text)
        XCTAssertEqual(a?.kind, .topic, text, line: line)
        XCTAssertEqual(a?.subject, subject, text, line: line)
    }

    func testTyposInTheAskWordsStillAsk() {
        topic("explain compued interest", "compued interest")
        topic("explian photosynthesis", "photosynthesis")
        topic("expalin the water cycle", "water cycle")
        XCTAssertEqual(Explain.detect("wat is inflation")?.subject, "inflation")
        XCTAssertEqual(Explain.detect("whats a CAGR")?.subject, "cagr")
        topic("how dose a heat pump wrok", "heat pump")
        topic("draw the water cycle", "water cycle")
        topic("draw me a heart", "heart")
    }

    func testEverydayChatStaysQuiet() {
        for text in ["why are you late", "how are you", "what time", "explains a lot", "wat r u doing", "draw it later", "what is up"] {
            XCTAssertNil(Explain.detect(text), text)
        }
    }
}

final class CryptoWordsTests: XCTestCase {
    /// A speller that calls crypto words and "teh" wrong and guesses an everyday word, as UITextChecker does for "usdt".
    private let wrong: FixCheck.Speller = { w in
        let lower = w.lowercased()
        if lower == "teh" { return .wrong(guesses: ["the"]) }
        return CryptoWords.all.contains(lower) || lower == "gst" ? .wrong(guesses: ["used", "the", "bar"]) : .ok
    }

    func testAutocorrectLeavesCryptoWordsAlone() {
        for w in ["usdt", "USDT", "Usdt", "usdc", "arb", "tron", "sol", "bnb", "doge", "xrp", "wnear", "testnet", "BTC", "GST", "Q4",
                  "iPhone15", "0x8ba1f109551bd432803012645ac136ddd64dba72", "ana.near", "bob.testnet", "vitalik.eth", "$5", "$0.02"] {
            XCTAssertNil(FixCheck.autocorrect("send 5 \(w)", spell: wrong), w)
        }
        // A real typo still gets fixed.
        XCTAssertEqual(FixCheck.autocorrect("send teh", spell: wrong)?.fixed, "the")
    }

    func testFixNeverOffersToChangeTokenSymbols() {
        XCTAssertNil(FixCheck.plan("Send 0.02 usdt to Ana on tron.", spell: wrong))
        XCTAssertNil(FixCheck.plan("Bridge 5 USDC to base and swap to ARB.", spell: wrong))
    }

    func testTheWordSlotsKnowCryptoWords() {
        XCTAssertTrue(CryptoWords.languageLines.contains("usdt\t"))
    }
}

final class SecretFilterTests: XCTestCase {
    static let secrets = [
        "0x4c0883a69102937d6231471b5dbb6204fe5129617082792ae468d01a3f362318",
        "4c0883a69102937d6231471b5dbb6204fe5129617082792ae468d01a3f362318",
        "my key is ed25519:3D4YudUahN1HMqD1XdzHtTpP1qBSnoA9uYCyonJxbJWvgTyxMo4spLMhCdwxhs9mBVKXFkc5yYkUwzBZ8rrtVuJr",
        "secp256k1:5JXbRqvTQiq3yVF8NbNzRzXyc1t7nU3ZRqhJM1dZmmCVTSvKZ3sxpbqJm5pJNBpWxXbqcLTKHuWqTqWYoDEJ7V1kdUDt",
        "5HueCGU8rMjxEXxiPuD5BDku4MkFqeZyd4dZ1jvhTVqvbTLvyTJ",
        "KwDiBf89QgGbjEhKnhXJuH7LrciVrZi3qYjgd9M7rFU73sVHnoWn",
        "L1aW4aubDFB7yfras2S1mN3bqg9nwySY8nkoLmJebSLD5BWv3ENZ",
        "4wBqpZM9xaSheZzJSMawUKKwhdpChKbZ5eu5ky4Vigw8fRqnJbHnSLkXXpCCDnqtwMd3EnUadk1QKbhmSMmCrNmE",
        "abandon ability able about above absent absorb abstract absurd abuse access accident",
        "legal winner thank year wave sausage worth useful legal winner thank yellow",
        "Letter advice cage absurd amount doctor acoustic avoid letter advice cage above",
        "zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo wrong",
        "here it is: abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about.",
        "sk_live_51HqLyjWDarjtT1zdp7dc",
        "pk_live_51HqLyjWDarjtT1zdp7dcXXX",
        "api_8f1b2c3d4e5f6a7b8c9d",
        "ghp_16C7e42F292c6912E7710c838347Ae178B4a",
        "xoxb-123456789012-123456789012-abc",
        "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U",
        "sk-proj-abcdefghijklmnop1234",
        "the code is 482913",
        "4111 1111 1111 1111",
        "card 5500-0000-0000-0004 exp 12/28",
        "P@ssw0rd!x",
        "my pass is Tr0ub4dor&3x",
        "wifi: Gr33n!Tea#42",
        "use hunter2Hunter! to log in",
        "Xk9#mQ2$vL",
        "pw S3cure_Pa55",
        "login with Abc$1234xyz",
        "AKIAIOSFODNN7EXAMPLE1234",
        "-----BEGIN PRIVATE KEY----- MIIEvQ",
    ]

    static let clean = [
        "iPhone15 is out", "COVID-19 rules changed", "it costs $5.20", "Q4 numbers look good", "mail me at ana@example.com",
        "send 5 usdc to ana.near", "send 10 usdc to 0x8ba1f109551bD432803012645Ac136ddd64DBA72 on base",
        "send $0.02 USDT to TJYeasTPa6gpEEfYjSbZMYV5v6mBB5hR8f", "pay 2 sol to 7EcDhSYGxXyscszYEp35KHN8vvw3svAuLKTzXwCFLtV",
        "send 0.001 btc to bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq",
        "send 1 near to 98793cd91a3f870fb126f66285808c7e094afcfc4eda8a970f6648cdf0dbd6de",
        "Windows11 update", "MacBookPro16 arrived", "meet at 10:30am", "on 12/11/2026", "Thanks!!", "Couldn't make it",
        "Well-known place", "Mother-in-law visits", "see https://pip.example/d/AbC123xyz", "www.Example-Site1.com",
        "@Ana_99 hey", "#Throwback2024", "50%off today", "x^2+1", "C++17 works", "it's 3x faster",
        "the weather is about to change", "abandon the plan and come home", "rent is $1,200.50", "Pixel9 Pro",
        "B12 vitamins", "4pm works", "call 98200 12345",
    ]

    func testSecretsAreCaught() {
        XCTAssertGreaterThanOrEqual(Self.secrets.count, 30)
        for s in Self.secrets { XCTAssertTrue(SecretFilter.isSecret(s), "missed: \(s)") }
    }

    func testEverydayTextIsNotASecret() {
        XCTAssertGreaterThanOrEqual(Self.clean.count, 30)
        for s in Self.clean { XCTAssertNil(SecretFilter.scan(s), "flagged: \(s) as \(String(describing: SecretFilter.scan(s)))") }
    }

    static let hisSentence = "send 0.02 near to pipfundmwg9zj421.mainnet"

    /// 20 recipients a payment names: NEAR named and implicit accounts, EVM, Tron, Bitcoin and Solana addresses.
    static let recipients = [
        "pipfundmwg9zj421.mainnet", "pipfundmwg9zj421.near", "pipfundmwg9zj421.testnet", "pipfundmwg9zj421", "ana.near",
        "alice_99.tg", "my-shop.near", "pay.pip.near", "a1b2c3d4e5.testnet", "relay_2024.near", "x9y8z7w6v5.near",
        "dev-1699999999999-12345678901234", "usdc.fakes.testnet", "@ana.near", "bob-7.tg",
        "98793cd91a3f870fb126f66285808c7e094afcfc4eda8a970f6648cdf0dbd6de",
        "0x8ba1f109551bD432803012645Ac136ddd64DBA72", "TJYeasTPa6gpEEfYjSbZMYV5v6mBB5hR8f",
        "bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq", "7EcDhSYGxXyscszYEp35KHN8vvw3svAuLKTzXwCFLtV",
    ]

    /// TestFlight 0.5: his pay sentence showed "Sensitive text detected" once ".m" was typed: the dot counted as a symbol,
    /// so lower + digit + "." made three classes. No prefix of it is a secret now.
    func testHisPaySentenceNeverFlagsAtAnyKey() {
        for n in 1...Self.hisSentence.count {
            let typed = String(Self.hisSentence.prefix(n))
            XCTAssertNil(SecretFilter.scan(typed), "flagged at \"\(typed)\"")
        }
    }

    func testRecipientsInAPaySentenceNeverFlag() {
        XCTAssertEqual(Self.recipients.count, 20)
        for r in Self.recipients {
            for verb in ["send 0.02 near to ", "pay 5 usdc to "] {
                let line = verb + r
                for n in 1...line.count {
                    let typed = String(line.prefix(n))
                    XCTAssertNil(SecretFilter.scan(typed), "flagged at \"\(typed)\" as \(String(describing: SecretFilter.scan(typed)))")
                }
            }
        }
    }

    /// Lower case and digits with account marks are two classes, not a password, even outside a payment.
    /// Outside a payment, 64 hex is a key and a 32-character dev account reads as a token, so those two stay out.
    func testAccountNamesAloneAreNotPasswords() {
        for r in Self.recipients where r.count != 64 && !r.hasPrefix("dev-") {
            XCTAssertNil(SecretFilter.scan("my account is \(r)"), "flagged: \(r)")
        }
    }

    func testFinishedWordsDropsTheWordBeingTyped() {
        XCTAssertEqual(SecretFilter.finishedWords("send 0.02 near to pipfund"), "send 0.02 near to")
        XCTAssertEqual(SecretFilter.finishedWords("hello"), "")
    }

    /// The 186-line router eval (server/test/fixtures/route-eval.json): no line is called a secret.
    func testNoFalsePositivesOnTheRouterEval() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../server/test/fixtures/route-eval.json")
        let eval = try JSONDecoder().decode([String: [String]].self, from: Data(contentsOf: url))
        let lines = eval.values.flatMap { $0 }
        XCTAssertEqual(lines.count, 186)
        let flagged = lines.filter(SecretFilter.isSecret)
        XCTAssertEqual(flagged, [], "false positives: \(flagged.count) of \(lines.count)")
    }

    func testMemoryNeverKeepsASecretAndHoldsTwentyLines() {
        var m = TypingMemory()
        m.add("abandon ability able about above absent absorb abstract absurd abuse access accident")
        XCTAssertEqual(m.lines, [])
        for i in 0..<25 { m.add("line \(i) here") }
        XCTAssertEqual(m.lines.count, TypingMemory.cap)
        XCTAssertEqual(m.context(), ["line 22 here", "line 23 here", "line 24 here"])
    }
}

final class PayDollarTests: XCTestCase {
    override func setUp() { Flags.dollarPay = true }
    /// TestFlight 0.4: "send $0.02 USDT to <address>" showed nothing: the phone's regex needed a digit right after "send".
    func testDollarAmountsAreCrossChainCandidates() {
        for t in ["send $0.02 USDT to TJYeasTPa6gpEEfYjSbZMYV5v6mBB5hR8f", "send 0.02 usdt to TJYeasTPa6gpEEfYjSbZMYV5v6mBB5hR8f",
                  "send $5 to 0x8ba1f109551bD432803012645Ac136ddd64DBA72", "send 5 bucks of usdc to 7EcDhSYGxXyscszYEp35KHN8vvw3svAuLKTzXwCFLtV"] {
            XCTAssertNotNil(XchainDetect.candidate(t), t)
        }
        XCTAssertNil(XchainDetect.candidate("send 5 to 0x8ba1f109551bD432803012645Ac136ddd64DBA72"), "no $ and no token: unclear")
    }

    func testDollarUSDCToANearAccountIsAPlainPay() {
        XCTAssertEqual(PayDetect.detect("send $5 usdc to ana.testnet")?.amount, "5")
        XCTAssertNil(PayDetect.detect("send $5 near to ana.testnet"), "$ with NEAR is unclear")
    }

    @MainActor func testAnEVMAddressAsksWhichChain() {
        let p = XchainParsed(valid: false, reason: "say which chain", needs: "chain")
        XCTAssertEqual(KeyboardModel.offer(p, words: "send $5 to 0x…"), .whichChain(trigger: "send $5 to 0x…"))
    }
}

@MainActor
final class RouteModelTests: XCTestCase {
    private var host: FakeHost!
    private var api: FakeAPI!
    private var clock: FakeClock!
    private var store: FakeStore!
    private var model: KeyboardModel!
    private var page: FakePage!

    override func setUp() async throws {
        SharedStore.payNetwork = "testnet"
        host = FakeHost()
        api = FakeAPI()
        clock = FakeClock()
        store = FakeStore()
        page = FakePage()
        model = KeyboardModel(deps: .fake(api: api, store: store, pasteboard: FakePasteboard(), clock: clock))
        model.host = host
        model.keyboardAppeared()
        KeyboardModel.secretPauseDelay = .milliseconds(30)
    }

    override func tearDown() { KeyboardModel.secretPauseDelay = .milliseconds(800) }

    private func set(_ text: String) {
        host.text = text
        model.textChanged()
    }

    private func until(_ what: String, _ cond: () -> Bool) async {
        for _ in 0..<500 where !cond() { await Task.yield() }
        XCTAssertTrue(cond(), "timed out waiting for \(what)")
    }

    private func pause(_ s: TimeInterval = 1.2) async {
        for _ in 0..<30 { await Task.yield() }
        clock.advance(s)
        for _ in 0..<50 { await Task.yield() }
    }

    private func ids() -> [String] { model.barItems.map(\.id) }

    /// The real-time pause that finishes the word being typed for the secret line.
    private func typingPause() async {
        try? await Task.sleep(for: .milliseconds(150))
        for _ in 0..<20 { await Task.yield() }
    }

    private func type(_ text: String) {
        for ch in text {
            let f = ObjectIdentifier(NSObject())
            let key = ch == " " ? KeyCap(id: "space", kind: .space, frame: .zero, a11y: "space")
                : KeyCap(id: String(ch), kind: .char(String(ch)), frame: .zero, a11y: String(ch))
            model.touchBegan(f, key)
            model.touchEnded(f)
            XCTAssertFalse(model.secretLine, "lock shown at \"\(host.text)\"")
        }
    }

    /// TestFlight 0.5: his sentence typed key by key never shows the lock, before or after a pause, and the bar says
    /// which endings a NEAR account has.
    func testHisPaySentenceTypedKeyByKeyNeverLocksAndExplainsTheEnding() async {
        host.autocapitalization = .none
        set("")
        type(SecretFilterTests.hisSentence)
        XCTAssertEqual(host.text, SecretFilterTests.hisSentence)
        await typingPause()
        XCTAssertFalse(model.secretLine)
        XCTAssertEqual(model.payItem?.title, PayDetect.suffixHelp)
        XCTAssertEqual(model.barItems.first?.title, PayDetect.suffixHelp)
    }

    /// A recipient pasted from the iOS menu arrives through textDidChange in one edit: it counts as a finished word.
    func testAPastedRecipientShowsThePayChipAndNeverLocks() async {
        host.autocapitalization = .none
        let cases = [("send 0.02 near to ", "ana.near"), ("send 0.02 near to ", "pipfundmwg9zj421.testnet"),
                     ("send 5 usdc to ", "0x8ba1f109551bD432803012645Ac136ddd64DBA72"),
                     ("send 5 usdt to ", "TJYeasTPa6gpEEfYjSbZMYV5v6mBB5hR8f"),
                     ("send 0.001 btc to ", "bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq")]
        for (words, recipient) in cases {
            set("")
            type(words)
            host.insert(recipient)
            model.textChanged()
            XCTAssertFalse(model.secretLine, "locked on pasted \(recipient)")
            // A cross-chain recipient waits 300 ms of real time for the server's parse (a live preview on testnet).
            for _ in 0..<3000 where model.payItem == nil { try? await Task.sleep(for: .milliseconds(1)) }
            XCTAssertNotNil(model.payItem, "no pay chip for pasted \(recipient)")
            XCTAssertEqual(model.barItems.first?.id, "pay", "\(recipient): \(ids())")
            await typingPause()
            XCTAssertFalse(model.secretLine, "locked after a pause on \(recipient)")
        }
    }

    /// A pasted password is a finished word: the lock shows at once, with no pause.
    func testAPastedPasswordLocksAtOnce() {
        set("my wifi password is ")
        host.insert("Gr33n!Tea#42")
        model.textChanged()
        XCTAssertTrue(model.secretLine)
        XCTAssertEqual(model.barItems.map(\.title), [BarItems.secretLine])
    }

    /// "explain compued interest": the server answers despite the typo; the bar shows the answer and Draw it side by side.
    func testExplainAndDrawItShowTogether() async {
        set("explain compued interest")
        await pause(KeyboardModel.explainDebounce.seconds)
        await until("answer") { model.explainOffer != nil }
        XCTAssertEqual(api.explained, ["explain compued interest"])
        XCTAssertEqual(ids(), ["explain", "draw"])
        XCTAssertEqual(model.drawItem?.title, "Draw it")
        XCTAssertFalse(model.showsWordSlots)
    }

    /// One tap on Draw it opens the drawing panel and asks for the scene. The text card never opens.
    func testDrawItOpensTheDrawingDirectly() async {
        set("explain compued interest")
        await pause(KeyboardModel.explainDebounce.seconds)
        await until("draw chip") { model.drawTopic != nil }
        model.visualPageReady(page)
        model.perform(.draw)
        guard case .visual(let v)? = model.explainPanel else { return XCTFail("no drawing panel: \(String(describing: model.explainPanel))") }
        XCTAssertEqual(v.subject, "compued interest")
        await until("scene") { api.calls.contains("visual") }
        XCTAssertEqual(api.explained.last, "compued interest")
    }

    /// The router says "understand" for a sentence no keyword catches: Draw it shows, then the answer beside it.
    func testRouterUnderstandShowsDrawItAndTheAnswer() async {
        api.routeReply = RouteResponse(label: "understand", confidence: 0.97, chips: [])
        set("difference between stocks and bonds")
        await pause()
        await until("route") { api.calls.contains("route") }
        await until("draw chip") { model.drawTopic != nil }
        XCTAssertEqual(model.drawTopic?.subject, "difference between stocks and bonds")
        await until("answer") { model.explainOffer != nil }
        XCTAssertEqual(ids(), ["explain", "draw"])
        XCTAssertEqual(api.explained, ["difference between stocks and bonds"])
    }

    func testRouterChartShowsTheDrawChip() async {
        api.routeReply = RouteResponse(label: "chart", confidence: 0.9, chips: [])
        set("show my spending as a picture please")
        await pause()
        await until("chart chip") { model.explainOffer != nil }
        XCTAssertEqual(model.barItems.first?.title, "Draw it")
    }

    /// Plain chat, "none", a low label and a failed call show nothing new.
    func testNoneOrAFailureShowsNothing() async {
        set("how was your day today")
        await pause()
        await until("route") { api.calls == ["route"] }
        XCTAssertNil(model.drawTopic)
        XCTAssertNil(model.explainOffer)
        api.routeFails = true
        set("why didn't you call me back")
        await pause()
        await until("second route") { api.routed.count == 2 }
        XCTAssertNil(model.drawTopic)
    }

    /// On testnet a cross-chain ask the router finds still goes to the server: it answers a live NEAR Intents preview.
    func testRouterXchainOnTestnetAsksForALivePreview() async {
        api.routeReply = RouteResponse(label: "xchain_pay", confidence: 0.9, chips: [])
        set("move my usdc over to arbitrum")
        await pause()
        await until("the chip") { model.payItem?.detail == "Review" }
        XCTAssertEqual(api.parsed, ["move my usdc over to arbitrum"])
    }

    /// The router's swap label reads the sentence on the server too.
    func testRouterSwapLabelOffersASwap() async {
        api.routeReply = RouteResponse(label: "swap", confidence: 0.9, chips: [])
        api.parseReply = XchainParsed(valid: true, kind: "swap", amount: "1", token: "USDC", chain: "near", from: "NEAR")
        set("turn one near into usdc please")
        await pause()
        await until("the swap chip") { model.payItem?.title == "Swap 1 NEAR to USDC" }
    }

    /// His 0.4 case: "$0.02 USDT" to a Tron address. On testnet the server reads it and the card is a live preview.
    func testDollarUSDTToTronShowsAChip() async {
        set("send $0.02 USDT to TJYeasTPa6gpEEfYjSbZMYV5v6mBB5hR8f")
        // The keyboard waits 300 ms of real time for the words to settle before it asks.
        for _ in 0..<3000 where model.payItem?.detail != "Review" { try? await Task.sleep(for: .milliseconds(1)) }
        XCTAssertEqual(model.payItem?.detail, "Review")
        XCTAssertEqual(api.parsed, ["send $0.02 USDT to TJYeasTPa6gpEEfYjSbZMYV5v6mBB5hR8f"])
    }

    /// The router gets the last lines from the typing memory as context.
    func testTheRouterGetsTheLastLinesAsContext() async {
        for line in ["hey", "are you free this week", "abandon ability able about above absent absorb abstract absurd abuse access accident"] {
            set(line)
            set("")
        }
        set("can we catch up soon then")
        await pause()
        await until("route") { !api.routed.isEmpty }
        XCTAssertEqual(api.routed.last?.context, ["hey", "are you free this week"], "the seed phrase is never kept")
    }

    /// Typing a password or a seed phrase and pressing return types exactly that, shows one quiet line, and makes no call.
    func testASecretIsTypedAsIsWithOneQuietLineAndNoCalls() async {
        host.autocapitalization = .none
        for secret in ["login is Tr0ub4dor&3x", "legal winner thank year wave sausage worth useful legal winner thank yellow"] {
            host.text = ""
            model.textChanged()
            for ch in secret {
                let f = ObjectIdentifier(NSObject())
                let key = ch == " " ? KeyCap(id: "space", kind: .space, frame: .zero, a11y: "space")
                    : KeyCap(id: String(ch), kind: .char(String(ch)), frame: .zero, a11y: String(ch))
                model.touchBegan(f, key)
                model.touchEnded(f)
            }
            XCTAssertEqual(host.text, secret, "typed exactly")
            XCTAssertFalse(model.secretLine, "the last word is still being typed")
            await typingPause()
            XCTAssertTrue(model.secretLine, "a pause finishes the word")
            XCTAssertEqual(model.barItems.map(\.title), [BarItems.secretLine])
            let r = ObjectIdentifier(NSObject())
            model.touchBegan(r, KeyCap(id: "return", kind: .ret, frame: .zero, a11y: "return"))
            model.touchEnded(r)
            XCTAssertEqual(host.text, secret + "\n", "return inserts exactly what was typed")
            await pause(3)
            XCTAssertEqual(api.calls, [], "no call for \(secret)")
            XCTAssertEqual(model.memory.lines, [])
        }
        set("")
        XCTAssertFalse(model.secretLine, "the line goes once the text is sent")
    }
}

/// With the router off, typing goes to /v1/suggest as before; with memory and $ pay off, neither runs.
@MainActor
final class RouterFlagOffTests: XCTestCase {
    func testWithTheFlagsOffTheOldPathsRun() async {
        let api = FakeAPI(), clock = FakeClock(), host = FakeHost()
        let model = KeyboardModel(deps: .fake(api: api, clock: clock))
        Flags.router = false; Flags.memory = false; Flags.dollarPay = false
        defer { Flags.router = true; Flags.memory = true; Flags.dollarPay = true }
        model.host = host
        model.keyboardAppeared()
        host.text = "can we sort out Ana's thing"
        model.textChanged()
        for _ in 0..<30 { await Task.yield() }
        clock.advance(SuggestPolicy.debounce.seconds)
        for _ in 0..<100 where api.calls.isEmpty { await Task.yield() }
        XCTAssertEqual(api.calls, ["suggest"])
        host.text = ""
        model.textChanged()
        XCTAssertEqual(model.memory.lines, [], "no typing memory")
        XCTAssertNil(XchainDetect.candidate("send $0.02 USDT to TJYeasTPa6gpEEfYjSbZMYV5v6mBB5hR8f"))
    }
}
