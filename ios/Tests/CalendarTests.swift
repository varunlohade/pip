import XCTest
@testable import Pip

/// The calendar panel's sums (free gaps, clashes, other times, the words to share) and the panel's flow in the model.
/// Plan tests use a fixed UTC calendar on the mock's week: Tue 17 Nov 2026 has Standup, Design review, Dentist and Gym.
final class CalendarPlanTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.firstWeekday = 1
        return c
    }()

    private func at(_ day: Int, _ h: Int, _ m: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 11, day: day, hour: h, minute: m))!
    }
    private func ev(_ title: String, _ day: Int, _ h: Int, _ m: Int, _ h2: Int, _ m2: Int) -> Appointment {
        Appointment(start: at(day, h, m), end: at(day, h2, m2), title: title)
    }

    /// Tuesday as drawn, plus Wednesday with a lunch.
    private var week: [Appointment] {
        [ev("Standup", 17, 9, 30, 10, 0), ev("Design review", 17, 11, 0, 12, 0), ev("Dentist", 17, 15, 30, 16, 30),
         ev("Gym", 17, 18, 0, 19, 0), ev("Lunch", 18, 12, 0, 14, 0)]
    }

    // MARK: joining the confirm line

    func testConfirmLineStartsANewSentence() {
        XCTAssertTrue(CalendarPlan.newSentence(after: "") == ("", ""))
        XCTAssertTrue(CalendarPlan.newSentence(after: "coffee at 3pm") == ("", ". "))
        XCTAssertTrue(CalendarPlan.newSentence(after: "coffee at 3pm  ") == ("  ", ". "))
        XCTAssertTrue(CalendarPlan.newSentence(after: "Sounds good.") == ("", " "))
        XCTAssertTrue(CalendarPlan.newSentence(after: "Sounds good! ") == ("", ""))
        XCTAssertTrue(CalendarPlan.newSentence(after: "Sure,") == ("", " "))
        XCTAssertTrue(CalendarPlan.newSentence(after: "coffee at 3pm\n") == ("", ""))
    }

    // MARK: free gaps

    func testFreeGapsBetweenEventsInWorkingHours() {
        let gaps = CalendarPlan.freeGaps(week, on: at(17, 0), now: at(16, 12), cal: cal)
        XCTAssertEqual(gaps, [DateInterval(start: at(17, 9), end: at(17, 9, 30)),
                              DateInterval(start: at(17, 10), end: at(17, 11)),
                              DateInterval(start: at(17, 12), end: at(17, 15, 30)),
                              DateInterval(start: at(17, 16, 30), end: at(17, 18))])
    }

    func testFreeGapsOnTodayStartAtTheNextHalfHour() {
        let gaps = CalendarPlan.freeGaps(week, on: at(17, 0), now: at(17, 12, 10), cal: cal)
        XCTAssertEqual(gaps.first, DateInterval(start: at(17, 12, 30), end: at(17, 15, 30)))
    }

    func testGapsShorterThanHalfAnHourAreLeftOut() {
        let tight = [ev("A", 20, 9, 0, 12, 0), ev("B", 20, 12, 20, 18, 0)]
        XCTAssertEqual(CalendarPlan.freeGaps(tight, on: at(20, 0), now: at(16, 8), cal: cal), [])
    }

    func testOverlappingEventsMakeOneBusyBlock() {
        let overlap = [ev("A", 20, 10, 0, 12, 0), ev("B", 20, 11, 0, 11, 30), ev("C", 20, 11, 45, 13, 0)]
        XCTAssertEqual(CalendarPlan.freeGaps(overlap, on: at(20, 0), now: at(16, 8), cal: cal),
                       [DateInterval(start: at(20, 9), end: at(20, 10)), DateInterval(start: at(20, 13), end: at(20, 18))])
    }

    func testAnEmptyDayIsFreeNineToSix() {
        XCTAssertEqual(CalendarPlan.freeGaps([], on: at(21, 0), now: at(16, 8), cal: cal), [DateInterval(start: at(21, 9), end: at(21, 18))])
    }

    func testDayRowsMixEventsAndFreeTimeInOrder() {
        let rows = CalendarPlan.rows(week, on: at(17, 0), now: at(17, 10, 5), cal: cal)
        let shape = rows.map { r -> String in
            switch r {
            case .event(let a, let past): return a.title + (past ? " (past)" : "")
            case .free(let g): return "Free until " + CalendarPlan.clock(g.end, cal: cal, meridiem: false)
            }
        }
        XCTAssertEqual(shape, ["Standup (past)", "Free until 11", "Design review", "Free until 3:30", "Dentist", "Free until 6", "Gym"])
    }

    // MARK: clashes

    func testClashFindsTheOverlappingEvent() {
        XCTAssertEqual(CalendarPlan.clash(DateInterval(start: at(17, 15, 30), end: at(17, 16, 30)), with: week)?.title, "Dentist")
        XCTAssertEqual(CalendarPlan.clash(DateInterval(start: at(17, 15), end: at(17, 16)), with: week)?.title, "Dentist")
    }

    func testBackToBackIsNotAClash() {
        XCTAssertNil(CalendarPlan.clash(DateInterval(start: at(17, 16, 30), end: at(17, 17, 30)), with: week))
        XCTAssertNil(CalendarPlan.clash(DateInterval(start: at(17, 14, 30), end: at(17, 15, 30)), with: week))
    }

    func testTryInsteadOffersTheNearestFreeStartThatDayThenAnotherDay() {
        let wanted = DateInterval(start: at(17, 15, 30), end: at(17, 16, 30))
        let alt = CalendarPlan.alternatives(for: wanted, events: week, now: at(17, 9, 41), cal: cal)
        // That day, 2:30 (ends as the dentist starts) and 4:30 (right after) are both an hour away: the earlier wins.
        // Wednesday is free at 3:30.
        XCTAssertEqual(alt, [at(17, 14, 30), at(18, 15, 30)])
        for d in alt { XCTAssertNil(CalendarPlan.clash(DateInterval(start: d, duration: wanted.duration), with: week)) }
    }

    func testTryInsteadSkipsAFullDay() {
        let full = [ev("Offsite", 20, 9, 0, 18, 0)]
        let alt = CalendarPlan.alternatives(for: DateInterval(start: at(20, 10), duration: 3600), events: full, now: at(16, 8), cal: cal)
        XCTAssertEqual(alt, [at(21, 10), at(22, 10)])
    }

    // MARK: share a time

    func testShareSlotsTakeTheFirstHourOrMoreOnEachDay() {
        let slots = CalendarPlan.shareSlots(week, from: at(17, 0), now: at(17, 12, 10), cal: cal)
        XCTAssertEqual(slots, [DateInterval(start: at(17, 12, 30), end: at(17, 14, 30)), DateInterval(start: at(18, 9), end: at(18, 11))])
    }

    func testShareTextIsTheExactDraft() {
        let slots = [DateInterval(start: at(17, 12, 30), end: at(17, 14)), DateInterval(start: at(18, 14), end: at(18, 16))]
        XCTAssertEqual(CalendarPlan.shareText(slots, now: at(17, 9), cal: cal), "How about Tue 12:30-2 PM? Wed 2-4 PM works too.")
    }

    func testShareTextAcrossNoonAndForOneSlot() {
        XCTAssertEqual(CalendarPlan.shareText([DateInterval(start: at(18, 11, 30), end: at(18, 13))], now: at(17, 9), cal: cal),
                       "How about Wed 11:30 AM-1 PM?")
        XCTAssertNil(CalendarPlan.shareText([], now: at(17, 9), cal: cal))
    }

    func testShareTextNamesTheDateAWeekOrMoreAway() {
        XCTAssertEqual(CalendarPlan.shareText([DateInterval(start: at(25, 10), end: at(25, 11))], now: at(17, 9), cal: cal),
                       "How about Nov 25 10-11 AM?")
    }

    func testConfirmLineAndChips() {
        XCTAssertEqual(CalendarPlan.confirmText(at(17, 14), now: at(17, 9), cal: cal), "Tue 2 PM works for me. See you there!")
        XCTAssertEqual(CalendarPlan.chipText(at(17, 14), sameDayAs: at(17, 0), cal: cal), "2:00 PM")
        XCTAssertEqual(CalendarPlan.chipText(at(18, 15), sameDayAs: at(17, 0), cal: cal), "Wed 3:00 PM")
        XCTAssertEqual(CalendarPlan.whenText(DateInterval(start: at(17, 15, 30), end: at(17, 16, 30)), cal: cal), "Tue 17, 3:30-4:30 PM")
    }

    func testPipLineIsOneQuietSentence() {
        XCTAssertEqual(CalendarPlan.line(week, on: at(17, 0), now: at(17, 13), cal: cal), "Dentist at 3:30 PM.")
        XCTAssertEqual(CalendarPlan.line(week, on: at(18, 0), now: at(17, 13), cal: cal), "Free 9 AM-12 PM Wed.")
        XCTAssertEqual(CalendarPlan.line([ev("Offsite", 20, 9, 0, 18, 0)], on: at(20, 0), now: at(17, 13), cal: cal), "Friday is full.")
    }

    func testMonthGridIsWholeWeeksFromSunday() {
        let grid = CalendarPlan.monthGrid(at(17, 0), cal: cal)
        XCTAssertEqual(grid.count, 35)
        XCTAssertEqual(grid.first, at(1, 0))
        XCTAssertEqual(grid.last, cal.date(from: DateComponents(year: 2026, month: 12, day: 5))!)
    }
}

/// The panel through the model, with an in-memory calendar.
@MainActor
final class CalendarModelTests: XCTestCase {
    private var host: FakeHost!
    private var clock: FakeClock!
    private var writer: FakeWriter!
    private var model: KeyboardModel!
    private let cal = Calendar.current

    override func setUp() async throws {
        host = FakeHost()
        clock = FakeClock()
        writer = FakeWriter()
        // 9:41 AM on the real day: NSDataDetector reads "3:30pm" against the real date.
        clock.now = time(9, 41)
        writer.calendar = [Appointment(start: time(15, 30), end: time(16, 30), title: "Dentist")]
        model = KeyboardModel(deps: .fake(api: FakeAPI(), clock: clock, writer: writer))
        model.host = host
        model.refreshAccess()
    }

    private func time(_ h: Int, _ m: Int = 0, days: Int = 0) -> Date {
        let day = cal.date(byAdding: .day, value: days, to: cal.startOfDay(for: Date()))!
        return cal.date(bySettingHour: h, minute: m, second: 0, of: day)!
    }

    func testOpenGrowsTheKeyboardAndReadsTheCalendar() {
        model.openCalendar()
        XCTAssertEqual(model.keyboardHeight, Theme.SystemKeyboard.calendarHeight)
        XCTAssertEqual(model.calendar?.selected, cal.startOfDay(for: clock.now))
        XCTAssertEqual(model.calendar?.events?.map(\.title), ["Dentist"])
        model.toggleCalendar()
        XCTAssertNil(model.calendar)
        XCTAssertEqual(model.keyboardHeight, Theme.SystemKeyboard.height)
    }

    func testWithoutReadAccessThePanelSaysSoAndHasNoEvents() {
        writer.canRead = false
        model.openCalendar()
        XCTAssertNotNil(model.calendar)
        XCTAssertNil(model.calendar?.events)
    }

    func testTypedPlanThatClashesShowsBusyAndOtherTimes() {
        host.text = "coffee with Ana at 3:30pm"
        model.openCalendar()
        model.startNewEvent()
        guard case .newEvent(let e)? = model.calendar?.screen else { return XCTFail("no new event screen") }
        XCTAssertEqual(e.when.start, time(15, 30))
        XCTAssertEqual(e.clash?.title, "Dentist")
        XCTAssertEqual(e.tryInstead.count, 2)
        XCTAssertEqual(e.tryInstead.first, time(14, 30))
    }

    func testAddPutsTheEventAndTheLineInThenUndoTakesBothBack() async {
        host.text = "Sounds good."
        model.openCalendar()
        model.startNewEvent()
        guard case .newEvent(let e)? = model.calendar?.screen else { return XCTFail("no new event screen") }
        model.addNewEvent()
        XCTAssertEqual(writer.events.count, 1)
        XCTAssertEqual(host.text, "Sounds good. " + e.message)
        XCTAssertEqual(model.calendar?.screen, .month)
        XCTAssertNotNil(model.calendar?.done)
        model.undoCalendarDone()
        XCTAssertEqual(writer.events.count, 0)
        XCTAssertEqual(host.text, "Sounds good.")
        XCTAssertNil(model.calendar?.done)
    }

    func testConfirmLineAfterATypedPlanIsItsOwnSentenceAndUndoRestoresThePlan() {
        host.text = "coffee with Ana at 3:30pm "
        model.openCalendar()
        model.startNewEvent()
        guard case .newEvent(let e)? = model.calendar?.screen else { return XCTFail("no new event screen") }
        model.addNewEvent()
        XCTAssertEqual(host.text, "coffee with Ana at 3:30pm. " + e.message)
        model.undoCalendarDone()
        XCTAssertEqual(host.text, "coffee with Ana at 3:30pm ")
    }

    func testUntickedMessageAddsOnlyTheEvent() {
        model.openCalendar()
        model.startNewEvent()
        model.toggleAlsoMessage()
        model.addNewEvent()
        XCTAssertEqual(writer.events.count, 1)
        XCTAssertEqual(host.text, "")
    }

    func testNoWriteAccessAddsNothing() {
        writer.granted = []
        model.openCalendar()
        model.startNewEvent()
        model.addNewEvent()
        XCTAssertTrue(writer.events.isEmpty)
    }

    func testShareShowsTheExactTextAndInsertsOnlyOnInsert() {
        model.openCalendar()
        model.startShare()
        guard case .share(let text?)? = model.calendar?.screen else { return XCTFail("no draft") }
        XCTAssertTrue(text.hasPrefix("How about "), text)
        XCTAssertEqual(host.text, "", "nothing goes in before Insert")
        model.insertShare()
        XCTAssertEqual(host.text, text)
        XCTAssertNil(model.calendar)
    }

    func testOtherPanelsCloseTheCalendar() {
        model.openCalendar()
        model.toggleNotes()
        XCTAssertNil(model.calendar)
        XCTAssertTrue(model.notesOpen)
        model.openCalendar()
        XCTAssertFalse(model.notesOpen)
        model.keyboardDisappeared()
        XCTAssertNil(model.calendar)
    }
}
