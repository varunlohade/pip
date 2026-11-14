import EventKit
import SwiftUI

/// Reads today's events from the phone calendar (Apple Calendar, with any Google calendars synced to it).
/// Events stay on the device. Only a small snapshot goes to the App Group, for the keyboard.
@MainActor
final class CalendarModel: ObservableObject {
    static let shared = CalendarModel()

    @Published var status = EKEventStore.authorizationStatus(for: .event)
    /// The keyboard adds reminders from typed text ("call supplier at 5"). The app asks; the keyboard cannot.
    @Published var remindersStatus = EKEventStore.authorizationStatus(for: .reminder)
    @Published var today: [Appointment] = []

    private let store = EKEventStore()
    private var changes: Any?

    var connected: Bool { status == .fullAccess }
    /// Either permission has never been asked, so the Connect card still shows.
    var neverAsked: Bool { status == .notDetermined || remindersStatus == .notDetermined }

    init() {
        changes = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func connect() async {
        if status == .notDetermined { _ = try? await store.requestFullAccessToEvents() }
        if remindersStatus == .notDetermined { _ = try? await store.requestFullAccessToReminders() }
        remindersStatus = EKEventStore.authorizationStatus(for: .reminder)
        refresh()
    }

    func refresh() {
        status = EKEventStore.authorizationStatus(for: .event)
        remindersStatus = EKEventStore.authorizationStatus(for: .reminder)
        guard connected else { today = []; SharedStore.appointments = []; return }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-calendarDemo") { seedDemo() }
        if ProcessInfo.processInfo.arguments.contains("-calendarWeekDemo") { seedWeek() }
        #endif
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        let events = store.events(matching: store.predicateForEvents(withStart: start, end: start.addingTimeInterval(86_400), calendars: nil))
        today = events.filter { !$0.isAllDay && cal.isDateInToday($0.startDate) }.sorted { $0.startDate < $1.startDate }
            .map { Appointment(start: $0.startDate, end: $0.endDate, title: $0.title ?? "Event") }
        SharedStore.appointments = today
    }

    #if DEBUG
    /// "-calendarDemo": four events for today, once. Two have ended, two are still to come.
    private func seedDemo() {
        let cal = Calendar.current
        let day = cal.startOfDay(for: Date())
        let marker = "pip-demo"
        let existing = store.events(matching: store.predicateForEvents(withStart: day, end: day.addingTimeInterval(86_400), calendars: nil))
        guard !existing.contains(where: { $0.notes == marker }), let target = store.defaultCalendarForNewEvents else { return }
        let now = Date()
        let lastStart = day.addingTimeInterval(86_400 - 1800)
        for (title, offset) in [("Dentist", -7200.0), ("Coffee with Ava", -3600), ("Team standup", 3600), ("Call mom", 9000)] {
            let e = EKEvent(eventStore: store)
            e.title = title
            e.startDate = min(max(now.addingTimeInterval(offset), day), lastStart)
            e.endDate = e.startDate.addingTimeInterval(1800)
            e.notes = marker
            e.calendar = target
            try? store.save(e, span: .thisEvent)
        }
    }

    /// "-calendarWeekDemo": the calendar mock's day (Standup, Design review, Dentist, Gym) today, and a few events
    /// over the next weeks, once. For the calendar panel's screenshots.
    private func seedWeek() {
        let cal = Calendar.current
        let day = cal.startOfDay(for: Date())
        let marker = "pip-week-demo"
        let existing = store.events(matching: store.predicateForEvents(withStart: day, end: day.addingTimeInterval(86_400), calendars: nil))
        guard !existing.contains(where: { $0.notes == marker }), let target = store.defaultCalendarForNewEvents else { return }
        let plan: [(String, Int, Double, Double)] = [
            ("Standup", 0, 9.5, 10), ("Design review", 0, 11, 12), ("Dentist", 0, 15.5, 16.5), ("Gym", 0, 18, 19),
            ("Lunch with Sam", 1, 12, 14), ("Standup", 1, 9.5, 10), ("Client call", 2, 10, 11), ("Standup", 3, 9.5, 10),
            ("Yoga", 5, 8, 9), ("Standup", 7, 9.5, 10), ("Review", 9, 14, 15), ("Dinner", 12, 19, 21),
        ]
        for (title, offset, from, to) in plan {
            guard let d = cal.date(byAdding: .day, value: offset, to: day) else { continue }
            let e = EKEvent(eventStore: store)
            e.title = title
            e.startDate = d.addingTimeInterval(from * 3600)
            e.endDate = d.addingTimeInterval(to * 3600)
            e.notes = marker
            e.calendar = target
            try? store.save(e, span: .thisEvent)
        }
    }
    #endif
}
