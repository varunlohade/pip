import XCTest
@testable import Pip

final class SuggestPolicyTests: XCTestCase {
    func testActionishSentenceAsksOnce() {
        var p = SuggestPolicy()
        let text = "can we do Ana's thing Friday"
        XCTAssertEqual(p.maybe(text, clear: false), text)
        p.markAsked(text)
        XCTAssertNil(p.maybe(text, clear: false), "a sentence goes once")
        XCTAssertNil(p.maybe(text + " after work", clear: false), "typing on in the same sentence does not ask again")
    }

    func testAClearPhoneMatchAsksNothing() {
        XCTAssertNil(SuggestPolicy().maybe("lunch with Ana tomorrow at 1", clear: true))
    }

    func testEmptyAsksNothing() {
        XCTAssertNil(SuggestPolicy().maybe("", clear: false))
    }

    func testPlainChatAsksNothing() {
        for text in ["ok", "see you", "haha that is so true"] {
            XCTAssertNil(SuggestPolicy().maybe(text, clear: false), text)
        }
    }

    func testShortcutPrefixNeverAsks() {
        for text in [";omw see you at 5", ";fix call Sam at 5 tomorrow"] {
            XCTAssertNil(SuggestPolicy().maybe(text, clear: false), text)
        }
    }

    func testCardNumberAsksNothing() {
        XCTAssertNil(SuggestPolicy().maybe("my card is 4242 4242 4242 4242 thanks", clear: false))
        XCTAssertNil(SuggestPolicy().maybe("card 4242-4242-4242-4242 for the trip", clear: false))
        XCTAssertNil(SuggestPolicy().maybe("card 4242424242424242 for the trip", clear: false))
    }

    func testSecretsAskNothing() {
        XCTAssertNil(SuggestPolicy().maybe("the code is 482913", clear: false))
        XCTAssertNil(SuggestPolicy().maybe("use key sk_live_abcdefghijklmnop1234 please", clear: false))
        XCTAssertNil(SuggestPolicy().maybe("token is aB3dE5gH7jK9mN1pQ3sT5vW7yZ9bC1dE3f ok", clear: false))
    }

    func testSentenceKeyIsTheFirstThreeWords() {
        XCTAssertEqual(SuggestPolicy.sentenceKey("Can we do Ana's thing"), "can we do")
    }
}

final class ShortcutEngineTests: XCTestCase {
    private let notes = [Note(text: "On my way!", trigger: ";omw")]
    private func match(_ before: String, actions: [ActionShortcut] = ActionShortcut.defaults) -> ShortcutEngine.Match? {
        ShortcutEngine.match(before: before, notes: notes, actions: actions)
    }

    func testNoteTrigger() {
        XCTAssertEqual(match("hi ;Omw"), .init(delete: 4, action: .insert("On my way!"), trigger: ";omw"))
    }

    func testFixTakesTheSpaceBefore() {
        XCTAssertEqual(match("teh cat ;fix"), .init(delete: 5, action: .fix, trigger: ";fix"))
        XCTAssertEqual(match(";fix"), .init(delete: 4, action: .fix, trigger: ";fix"))
    }

    func testNoMatch() {
        XCTAssertNil(match(";pay 45"))
        XCTAssertNil(match("x"))
        XCTAssertNil(match("hello world"))
        XCTAssertNil(match("abc;fix"))
        XCTAssertNil(match(";fix ")) // the trigger must be the last word
    }

    func testDisabledActionDoesNothing() {
        var off = ActionShortcut.defaults
        off[0].enabled = false
        XCTAssertNil(match(";fix", actions: off))
    }
}

final class AppointmentRulesTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func appt(_ startH: Double, _ title: String) -> Appointment {
        Appointment(start: t0 + startH * 3600, end: t0 + (startH + 1) * 3600, title: title)
    }

    func testNextUp() {
        let list = [appt(0, "a"), appt(2, "b"), appt(3, "c")]
        XCTAssertEqual(AppointmentRules.nextUp(list, now: t0 + 1 * 3600)?.title, "b")
        XCTAssertNil(AppointmentRules.nextUp(list, now: t0 + 3 * 3600))
    }
}

final class BarItemsTests: XCTestCase {
    private func state(_ bar: BarState = .idle) -> BarItems.State {
        .init(hasFullAccess: true, paired: true, undo: nil, hasCalmOffer: false, bar: bar, copiedAvailable: false, nextUp: nil)
    }

    func testNoFullAccessIsOneInfoLine() {
        var s = state()
        s.hasFullAccess = false
        XCTAssertEqual(BarItems.build(s).map(\.id), ["info"])
    }

    func testIdleOffersAtMostThree() {
        var s = state()
        s.copiedAvailable = true
        s.hasCalmOffer = true
        s.nextUp = Appointment(start: .now, end: .now, title: "Dentist")
        s.smart = []
        XCTAssertEqual(BarItems.build(s).map(\.id), ["calm", "copied", "next"])
    }

    func testWorkingAndDoneAreOneQuietLine() {
        XCTAssertEqual(BarItems.build(state(.working("Fixing\u{2026}"))).map(\.tone), [.secondary])
        XCTAssertEqual(BarItems.build(state(.done("Looks good \u{2713}"))).map(\.title), ["Looks good \u{2713}"])
    }

    func testErrorIsDueTone() {
        XCTAssertEqual(BarItems.build(state(.error("No connection"))).first?.tone, .warning)
    }
}
