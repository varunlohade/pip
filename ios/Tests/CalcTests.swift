import XCTest
@testable import Pip

/// Sums, tip and split, units, time zones and currency, read on the phone.
final class CalcTests: XCTestCase {
    /// 2026-11-13 10:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_794_564_000)
    private let utc = TimeZone(identifier: "UTC")!
    private let rates = Calc.Rates(base: "USD", date: "2026-11-12", fetched_at: Date(timeIntervalSince1970: 1_794_564_000 - 1800),
                                   rates: ["USD": 1, "INR": 94.04, "EUR": 0.90245, "GBP": 0.7544])

    private func answer(_ text: String) -> Calc.Answer? { Calc.detect(text, now: now, zone: utc, rates: rates) }

    private func chip(_ text: String, _ title: String, line: UInt = #line) {
        XCTAssertEqual(answer(text)?.title, title, text, line: line)
    }

    func testMath() {
        chip("12*7", "= 84")
        chip("1200/3", "= 400")
        chip("(45+30)*1.18", "= 88.5")
        chip("12 x 7", "= 84")
        chip("12\u{00D7}7", "= 84")
        chip("2^10", "= 1,024")
        chip("1,200 + 350", "= 1,550")
        chip("100-35", "= 65")
        chip("what's 15*4?", "= 60")
        chip("ok. 100/40", "= 2.5")
        chip("12*7=", "= 84")
        chip("18% of 2450", "= 441")
        chip("20% off 80", "$64.00 ($16.00 off)")
    }

    func testTipAndSplit() {
        chip("tip 18% on 64", "$11.52 tip \u{00B7} $75.52 total")
        chip("18% tip on $64", "$11.52 tip \u{00B7} $75.52 total")
        chip("split 120 4 ways", "$30.00 each")
        chip("split 87.50 between 3", "$29.17 each")
        chip("split \u{20AC}90 3 ways", "\u{20AC}30.00 each")
        chip("Split 1,000 among 4 people", "$250.00 each")
    }

    func testUnits() {
        chip("5 km in miles", "3.11 mi")
        chip("72f to c", "22.22 \u{00B0}C")
        chip("30 c to f", "86 \u{00B0}F")
        chip("3 cups to ml", "709.76 ml")
        chip("10 lbs to kg", "4.54 kg")
        chip("60 mph in km/h", "96.56 km/h")
        chip("how many ml in 2 tbsp", "29.57 ml")
        chip("5'10 in cm", "177.8 cm")
        chip("5k in miles", "3.11 mi")
    }

    func testTimeZones() {
        chip("3pm PST in IST", "4:30 AM IST, next day")
        chip("15:30 utc to tokyo", "12:30 AM Tokyo, next day")
        chip("9am est to london", "2:00 PM London")
        chip("what's 9am in london?", "9:00 AM London")
        chip("what time is it in London", "10:00 AM in London")
        chip("time in tokyo", "7:00 PM in Tokyo")
    }

    func testCurrency() {
        chip("100 usd to inr", "\u{20B9}9,404.00")
        chip("$20 in euros", "\u{20AC}18.05")
        chip("50 gbp to usd", "$66.28")
        XCTAssertEqual(answer("100 usd to inr")?.note, "as of 9:30 AM")
        // Without rates there is no chip; the keyboard fetches them.
        XCTAssertNil(Calc.detect("100 usd to inr", now: now, zone: utc, rates: nil))
        XCTAssertEqual(Calc.read("100 usd to inr")?.ask.needsRates, true)
        // Pounds of weight stay a weight.
        chip("5 pounds to kg", "2.27 kg")
    }

    func testInsertReplacesTheAsk() {
        XCTAssertEqual(answer("12*7")?.insert, "12*7 = 84")
        XCTAssertEqual(answer("split 120 4 ways")?.insert, "$30.00 each")
        XCTAssertEqual(answer("5 km in miles")?.insert, "5 km = 3.11 mi")
        XCTAssertEqual(answer("100 usd to inr")?.insert, "$100.00 = \u{20B9}9,404.00")
    }

    /// Plain chat that only holds numbers never gets a chip.
    func testChatWithNumbersIsQuiet() {
        for text in [
            "call me at 5", "I'm 25", "it was 20 bucks lol", "555-123-4567", "+1 555 123 4567", "555-1234",
            "11/13", "11/13/2026", "24/7", "50/50", "2-3", "9-5", "the score was 3-2", "1990-2000", "100",
            "room 101", "top 10 songs", "2 for 1", "my code is 4521", "5 min to go", "5 people to dinner",
            "I have 3 cups of coffee", "meet at 3pm in the lobby", "see you at 3pm in paris", "3pm in london",
            "tip was great", "split the bill", "x^2", "lol 5+", "had a great time in paris", "ok 1 sec",
            "it's 2 to 3 hours", "1+1=2", "version 1.2.3", "back in 5", "we're 4 ways from home",
        ] {
            XCTAssertNil(answer(text), text)
        }
    }

    func testOnlyTheLastSentence() {
        chip("thanks for dinner! split 120 4 ways", "$30.00 each")
        XCTAssertNil(answer("12*7. thanks"))
    }
}

/// The keyboard flow: the sky chip shows the answer at once with no server call, and a tap types it in.
@MainActor
final class CalcModelTests: XCTestCase {
    private var host: FakeHost!
    private var api: FakeAPI!
    private var store: FakeStore!
    private var model: KeyboardModel!

    override func setUp() async throws {
        host = FakeHost()
        api = FakeAPI()
        store = FakeStore()
        model = KeyboardModel(deps: .fake(api: api, store: store))
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

    func testSplitChipNeedsNoServerAndTapReplacesTheAsk() async {
        set("dinner was great. split 120 4 ways")
        XCTAssertEqual(model.explainItem?.title, "$30.00 each")
        XCTAssertEqual(model.explainItem?.trigger, "split 120 4 ways")
        XCTAssertEqual(model.barItems.first?.id, "explain")
        XCTAssertFalse(model.explainOfferHasMore)
        model.tapExplainChip()
        XCTAssertEqual(host.text, "dinner was great. $30.00 each")
        XCTAssertNil(model.explainOffer)
        XCTAssertNil(model.explainPanel)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(api.calls, [])
        XCTAssertTrue(store.learned.isEmpty)
    }

    /// After a space the word slots guess the next word, but a calc chip still owns the bar.
    func testCalcChipShowsAfterASpaceOverWordSlots() async {
        set("split 120 4 ways ")
        for _ in 0..<500 where model.words.slots.isEmpty { try? await Task.sleep(for: .milliseconds(2)) }
        XCTAssertFalse(model.words.slots.isEmpty, "next-word guesses are ready")
        XCTAssertEqual(model.explainItem?.title, "$30.00 each")
        XCTAssertEqual(model.barItems.first?.id, "explain")
        XCTAssertFalse(model.showsWordSlots)
    }

    func testMathTapKeepsTheWorking() {
        set("12*7")
        model.perform(.explain)
        XCTAssertEqual(host.text, "12*7 = 84")
        model.textChanged()
        XCTAssertNil(model.explainOffer)
    }

    func testWhatsASumNeverGoesToExplain() async {
        set("what's 15*4?")
        XCTAssertEqual(model.explainItem?.title, "= 60")
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(api.calls.contains("explain"))
        XCTAssertFalse(api.calls.contains("route"))
    }

    func testCurrencyFetchesRatesOnceThenWorksFromTheCache() async {
        set("100 usd to inr")
        XCTAssertNil(model.explainOffer)
        await until("rates") { model.explainItem != nil }
        XCTAssertEqual(model.explainItem?.title, "\u{20B9}9,404.00")
        XCTAssertNotNil(model.explainItem?.detail)
        XCTAssertNotNil(store.currencyRates)
        set("50 usd to eur")
        XCTAssertEqual(model.explainItem?.title, "\u{20AC}45.12")
        XCTAssertEqual(api.calls, ["rates"])
    }

    func testRatesAreReadOnceThenKeptInMemory() {
        store.currencyRates = api.ratesReply
        set("100 usd to inr")
        set("100 usd to eur")
        set("50 usd to eur")
        XCTAssertEqual(model.explainItem?.title, "\u{20AC}45.12")
        XCTAssertEqual(store.ratesReads, 1, "one read, then memory")
    }

    func testCurrencyOfflineUsesTheLastRates() async {
        store.currencyRates = api.ratesReply
        api.ratesFail = true
        set("100 usd to inr")
        XCTAssertEqual(model.explainItem?.title, "\u{20B9}9,404.00")
    }
}
