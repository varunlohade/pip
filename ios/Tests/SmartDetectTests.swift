import XCTest
@testable import Pip

/// On-device reading of events, reminders and notes. NSDataDetector reads "tomorrow" against the real clock,
/// so `now` is today at 4:00 PM and each row checks the day and the hour, not a fixed date.
final class SmartDetectTests: XCTestCase {
    private let cal = Calendar.current
    private lazy var now = cal.date(bySettingHour: 16, minute: 0, second: 0, of: Date())!
    private lazy var tomorrow = cal.date(byAdding: .day, value: 1, to: now)!

    private enum Want {
        case event(String, hour: Int?, day: Date? = nil, weekday: Int? = nil)
        case reminder(String, hour: Int, minute: Int = 0, day: Date? = nil)
        case reminderIn(String, minutes: Double)
        case note(String)
    }

    private func check(_ text: String, _ want: [Want], trigger: String? = nil, line: UInt = #line) {
        let got = SmartDetect.detect(text, now: now, calendar: cal)
        XCTAssertEqual(got.count, want.count, "\(text): \(got)", line: line)
        if let trigger { XCTAssertEqual(got.first?.trigger, trigger, text, line: line) }
        for (g, w) in zip(got, want) {
            switch (g.action, w) {
            case let (.event(title, start, end), .event(wt, hour, day, weekday)):
                XCTAssertEqual(title, wt, text, line: line)
                if let hour {
                    XCTAssertEqual(cal.component(.hour, from: start), hour, text, line: line)
                    XCTAssertEqual(end, start.addingTimeInterval(3600), "\(text): one hour", line: line)
                } else {
                    XCTAssertNil(end, "\(text): all day", line: line)
                }
                if let day { XCTAssertTrue(cal.isDate(start, inSameDayAs: day), "\(text): \(start)", line: line) }
                if let weekday { XCTAssertEqual(cal.component(.weekday, from: start), weekday, text, line: line) }
                XCTAssertGreaterThan(start, cal.startOfDay(for: now), "\(text): not in the past", line: line)
            case let (.reminder(title, due), .reminder(wt, hour, minute, day)):
                XCTAssertEqual(title, wt, text, line: line)
                XCTAssertEqual(cal.component(.hour, from: due), hour, text, line: line)
                XCTAssertEqual(cal.component(.minute, from: due), minute, text, line: line)
                XCTAssertGreaterThan(due, now, "\(text): a past time rolls forward", line: line)
                if let day { XCTAssertTrue(cal.isDate(due, inSameDayAs: day), "\(text): \(due)", line: line) }
            case let (.reminder(title, due), .reminderIn(wt, minutes)):
                XCTAssertEqual(title, wt, text, line: line)
                XCTAssertEqual(due.timeIntervalSince(now), minutes * 60, accuracy: 1, text, line: line)
            case let (.note(body), .note(wt)):
                XCTAssertEqual(body, wt, text, line: line)
            default:
                XCTFail("\(text): got \(g.action)", line: line)
            }
        }
    }

    func testTable() {
        check("meeting with Ana tomorrow 3pm", [.event("Meeting with Ana", hour: 15, day: tomorrow)], trigger: "tomorrow 3pm")
        check("lol ok", [])
        // A sign-off, not a plan: no task or meeting word, so nothing. A chip on every "see you" would be noise.
        check("see you tomorrow", [])
        check("see you at 5", [])
        check("dentist friday 10am", [.event("Dentist", hour: 10, weekday: 6)], trigger: "friday 10am")
        check("call supplier at 5", [.reminder("Call supplier", hour: 17, day: now)], trigger: "at 5")
        check("remind me in 20 min to check oven", [.reminderIn("Check oven", minutes: 20)], trigger: "in 20 min")
        check("call mom in 2 hours", [.reminderIn("Call mom", minutes: 120)])
        check("need to buy shampoo", [.note("Buy shampoo")], trigger: "need to buy")
        check("haircut tomorrow", [.event("Haircut", hour: nil, day: tomorrow)], trigger: "tomorrow")
        check("remind me at 5pm to call mom", [.reminder("Call mom", hour: 17, day: now)], trigger: "at 5pm")
        // 3:30 with no AM/PM is afternoon; at 4 PM it has passed, so it rolls to tomorrow.
        check("pick up kids at 3:30", [.reminder("Pick up kids", hour: 15, minute: 30, day: tomorrow)])
        check("lunch with Sam on Tuesday at 1", [.event("Lunch with Sam", hour: 13, weekday: 3)])
        check("call Bo tonight", [.reminder("Call Bo", hour: 19, day: now)], trigger: "tonight")
        check("dinner at 8", [.event("Dinner", hour: 20, day: now)], trigger: "at 8")
        check("remind me tomorrow to pay rent", [.reminder("Pay rent", hour: 9, day: tomorrow)])
        check("note: gate code is 4521", [.note("Gate code is 4521")], trigger: "note")
        check("todo send the deck to Ana", [.note("Send the deck to Ana")])
        check("Sounds good. Meeting with Ana tomorrow 3pm", [.event("Meeting with Ana", hour: 15, day: tomorrow)])
        check("appointment with Sam Okafor thursday 2pm", [.event("Appointment with Sam Okafor", hour: 14, weekday: 5)])
        check(";omw tomorrow 3pm meeting", [])
        check("meeting 4242 4242 4242 4242 tomorrow 3pm", [])
        check("thanks so much, that was great", [])
    }

    func testTriggers() {
        XCTAssertEqual(SmartDetect.detect("ok. call supplier at 5", now: now).first?.trigger, "at 5")
    }

    func testLabels() {
        let tue = cal.nextDate(after: now, matching: DateComponents(hour: 15, weekday: 3), matchingPolicy: .nextTime)!
        let event = SmartChip(action: .event(title: "Meeting", start: tue, end: tue.addingTimeInterval(3600)), trigger: "tue 3pm")
        XCTAssertEqual(event.label(now: now), "Add to calendar \u{00B7} Tue 3:00 PM")
        XCTAssertEqual(event.doneLabel(now: now), "Added to Calendar \u{00B7} Tue 3:00 PM \u{2713}")
        let five = cal.date(bySettingHour: 17, minute: 0, second: 0, of: now)!
        XCTAssertEqual(SmartChip(action: .reminder(title: "Call", due: five), trigger: "at 5").label(now: now), "Remind me 5:00 PM")
        XCTAssertEqual(SmartChip(action: .note(text: "x"), trigger: "note").label(now: now), "Save note")
    }

    func testAClearDeviceMatchSkipsTheServer() {
        XCTAssertNil(SuggestPolicy().maybe("remind me in 20 min to check oven", clear: true))
        XCTAssertNil(SuggestPolicy().maybe("need to buy shampoo for Ana", clear: true))
        XCTAssertEqual(SuggestPolicy().maybe("need to buy shampoo for Ana", clear: false), "need to buy shampoo for Ana")
    }

    func testMaybeAsksOncePerSentenceAndNeverForPlainChat() {
        var policy = SuggestPolicy()
        XCTAssertNil(policy.maybe("lol ok see you", clear: false))
        XCTAssertNil(policy.maybe("haha that is so funny", clear: false))
        XCTAssertNil(policy.maybe("call supplier at 5 today", clear: true), "a clear match needs no server")
        let s = policy.maybe("Great. can we move Ana's thing", clear: false)
        XCTAssertEqual(s, "can we move Ana's thing")
        policy.markAsked(s!)
        XCTAssertNil(policy.maybe("Great. can we move Ana's thing", clear: false), "same sentence: never twice")
        XCTAssertNil(policy.maybe("Great. can we move Ana's thing to", clear: false), "one more word: not yet")
        XCTAssertEqual(policy.maybe("Great. can we move Ana's thing to next week", clear: false), "can we move Ana's thing to next week",
                       "grown by two words or more: asked again")
        XCTAssertNotNil(policy.maybe("Great. can we move Ana's thing to next week. Also ping Bo about the deck", clear: false))
    }
}

final class ReadyChipsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func appt(_ title: String, _ minutes: Double) -> Appointment {
        Appointment(start: now.addingTimeInterval(minutes * 60), end: now.addingTimeInterval(minutes * 60 + 1800), title: title)
    }

    func testNoDataGivesNotes() {
        XCTAssertEqual(ReadyChips.build(.init()).map(\.title), ["Notes"])
    }

    func testOrderByUsefulness() {
        let next = appt("Dentist", 30)
        let items = ReadyChips.build(.init(nextUp: next, today: [appt("Coffee", -60), next, appt("Call mom", 90)]))
        XCTAssertEqual(items.map(\.title), ["Next: \(next.time)", "Today", "Notes"])
        XCTAssertEqual(items.map(\.detail), ["Dentist", "3 events", nil])
        XCTAssertNil(items[0].action, "Next only informs")
    }

    func testCopiedComesFirst() {
        let items = ReadyChips.build(.init(copiedAvailable: true, today: [appt("Coffee", -60)]))
        XCTAssertEqual(items.map(\.title), ["Use copied message", "Today", "Notes"])
        XCTAssertEqual(items[1].detail, "1 event")
    }

    func testNextIsOnlyInformation() {
        let items = ReadyChips.build(.init(nextUp: appt("Dentist", 30)))
        XCTAssertEqual(items.first?.tone, .secondary)
        XCTAssertNil(items.first?.action)
    }
}
