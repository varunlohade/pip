import EventKit
import Foundation

enum SmartAccess: Equatable {
    case ready
    /// Keyboards without Full Access are kept away from the calendar, reminders and notes.
    case needsFullAccess
    /// The app has not been allowed to use the calendar or reminders, or was refused.
    case needsPermission
}

/// The phone's calendar and reminders, from the keyboard. A keyboard cannot show the permission prompt, so the
/// app asks (Connect Calendar); with that answer and Full Access on, the keyboard adds and removes items itself.
protocol SmartWriter: AnyObject {
    func access(_ place: SmartChip.Place, hasFullAccess: Bool) -> SmartAccess
    /// `end` nil: an all-day event. Returns the new item's identifier, for Undo.
    func addEvent(title: String, start: Date, end: Date?) throws -> String
    func addReminder(title: String, due: Date) throws -> String
    func removeEvent(_ id: String) throws
    func removeReminder(_ id: String) throws
    /// Timed events that overlap the range, from every calendar. Nil when the keyboard may not read them:
    /// Full Access is off, or the app was given write-only access or none.
    func events(from: Date, to: Date, hasFullAccess: Bool) -> [Appointment]?
}

final class EventKitWriter: SmartWriter {
    enum Failure: Error { case noCalendar, notFound }

    private lazy var store = EKEventStore()

    func access(_ place: SmartChip.Place, hasFullAccess: Bool) -> SmartAccess {
        guard hasFullAccess else { return .needsFullAccess }
        switch place {
        case .notes: return .ready
        case .calendar:
            let s = EKEventStore.authorizationStatus(for: .event)
            return s == .fullAccess || s == .writeOnly ? .ready : .needsPermission
        case .reminders:
            return EKEventStore.authorizationStatus(for: .reminder) == .fullAccess ? .ready : .needsPermission
        }
    }

    func addEvent(title: String, start: Date, end: Date?) throws -> String {
        guard let calendar = store.defaultCalendarForNewEvents else { throw Failure.noCalendar }
        let e = EKEvent(eventStore: store)
        e.title = title
        e.isAllDay = end == nil
        e.startDate = end == nil ? Calendar.current.startOfDay(for: start) : start
        e.endDate = end ?? e.startDate
        e.calendar = calendar
        try store.save(e, span: .thisEvent, commit: true)
        return e.eventIdentifier
    }

    func addReminder(title: String, due: Date) throws -> String {
        guard let list = store.defaultCalendarForNewReminders() else { throw Failure.noCalendar }
        let r = EKReminder(eventStore: store)
        r.title = title
        r.calendar = list
        r.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
        r.addAlarm(EKAlarm(absoluteDate: due))
        try store.save(r, commit: true)
        return r.calendarItemIdentifier
    }

    func removeEvent(_ id: String) throws {
        guard let e = store.event(withIdentifier: id) else { throw Failure.notFound }
        try store.remove(e, span: .thisEvent, commit: true)
    }

    func removeReminder(_ id: String) throws {
        guard let r = store.calendarItem(withIdentifier: id) as? EKReminder else { throw Failure.notFound }
        try store.remove(r, commit: true)
    }

    func events(from: Date, to: Date, hasFullAccess: Bool) -> [Appointment]? {
        guard hasFullAccess, EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return nil }
        return store.events(matching: store.predicateForEvents(withStart: from, end: to, calendars: nil))
            .filter { !$0.isAllDay }
            .sorted { $0.startDate < $1.startDate }
            .map { Appointment(start: $0.startDate, end: $0.endDate, title: $0.title ?? "Event", color: $0.calendar.map { Self.hex($0.cgColor) }) }
    }

    private static func hex(_ c: CGColor?) -> UInt32 {
        guard let rgb = c?.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components, rgb.count >= 3 else { return 0x00B3FF }
        func byte(_ v: CGFloat) -> UInt32 { UInt32(max(0, min(255, (v * 255).rounded()))) }
        return byte(rgb[0]) << 16 | byte(rgb[1]) << 8 | byte(rgb[2])
    }
}
