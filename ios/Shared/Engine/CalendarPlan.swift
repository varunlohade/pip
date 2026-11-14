import Foundation

/// The calendar panel's sums: free gaps, clashes, other times and the words to share. Pure: the caller passes the
/// events, the clock and the calendar.
enum CalendarPlan {
    /// Free time is looked for between these hours.
    static let dayStartHour = 9
    static let dayEndHour = 18
    /// A shorter gap is not worth offering.
    static let minGap: TimeInterval = 30 * 60
    /// A shared time is at most this long: "12:30-2 PM", not the whole afternoon.
    static let maxShare: TimeInterval = 2 * 3600

    /// One row of the day list: an event, or the free time before the next one.
    enum Row: Equatable, Identifiable {
        case event(Appointment, past: Bool)
        case free(DateInterval)
        var id: String {
            switch self {
            case .event(let a, _): "e|" + a.id
            case .free(let g): "f|\(g.start.timeIntervalSince1970)"
            }
        }
        var start: Date {
            switch self {
            case .event(let a, _): a.start
            case .free(let g): g.start
            }
        }
    }

    /// Free time of 30 min or more on `day`, between 9 AM and 6 PM. On today, it starts at the next half hour after `now`.
    static func freeGaps(_ events: [Appointment], on day: Date, now: Date, cal: Calendar) -> [DateInterval] {
        let midnight = cal.startOfDay(for: day)
        guard var cursor = cal.date(bySettingHour: dayStartHour, minute: 0, second: 0, of: midnight),
              let close = cal.date(bySettingHour: dayEndHour, minute: 0, second: 0, of: midnight) else { return [] }
        if now > cursor { cursor = roundUp(now, cal: cal) }
        var out: [DateInterval] = []
        for e in events.sorted(by: { $0.start < $1.start }) where e.end > cursor && e.start < close {
            if e.start.timeIntervalSince(cursor) >= minGap { out.append(DateInterval(start: cursor, end: e.start)) }
            cursor = max(cursor, e.end)
        }
        if close.timeIntervalSince(cursor) >= minGap { out.append(DateInterval(start: cursor, end: close)) }
        return out
    }

    /// The day list: events in time order with the free gaps between them.
    static func rows(_ events: [Appointment], on day: Date, now: Date, cal: Calendar) -> [Row] {
        let list = events.filter { cal.isDate($0.start, inSameDayAs: day) }.map { Row.event($0, past: $0.end <= now) }
        return (list + freeGaps(events, on: day, now: now, cal: cal).map(Row.free)).sorted { $0.start < $1.start }
    }

    /// The first event that overlaps the wanted time, or nil.
    static func clash(_ wanted: DateInterval, with events: [Appointment]) -> Appointment? {
        events.sorted { $0.start < $1.start }.first { $0.start < wanted.end && $0.end > wanted.start }
    }

    /// Up to two free starts for the same length, one per day: the nearest on the wanted day, then on the days after.
    /// `events` must cover the wanted day and the 6 days after it.
    static func alternatives(for wanted: DateInterval, events: [Appointment], now: Date, cal: Calendar) -> [Date] {
        let wantedDay = cal.startOfDay(for: wanted.start)
        let clock = wanted.start.timeIntervalSince(wantedDay)
        var out: [Date] = []
        for offset in 0..<7 {
            guard let day = cal.date(byAdding: .day, value: offset, to: wantedDay) else { continue }
            let target = day.addingTimeInterval(clock)
            let fits = freeGaps(events, on: day, now: now, cal: cal).compactMap { g -> Date? in
                let latest = g.end.addingTimeInterval(-wanted.duration)
                guard latest >= g.start else { return nil }
                return roundDown(min(max(target, g.start), latest), floor: g.start, cal: cal)
            }
            if let best = fits.min(by: { abs($0.timeIntervalSince(target)) < abs($1.timeIntervalSince(target)) }) {
                out.append(best)
                if out.count == 2 { break }
            }
        }
        return out
    }

    /// Times to offer in a chat: the first gap of an hour or more on each of the next free days, from `from` on, up to `count`.
    static func shareSlots(_ events: [Appointment], from: Date, now: Date, cal: Calendar, count: Int = 2) -> [DateInterval] {
        var out: [DateInterval] = []
        let first = cal.startOfDay(for: max(from, now))
        for offset in 0..<7 where out.count < count {
            guard let day = cal.date(byAdding: .day, value: offset, to: first) else { continue }
            if let g = freeGaps(events, on: day, now: now, cal: cal).first(where: { $0.duration >= 3600 }) {
                out.append(DateInterval(start: g.start, duration: min(g.duration, maxShare)))
            }
        }
        return out
    }

    /// "How about Tue 12:30-2 PM? Wed 2-4 PM works too." Nil when there is nothing to offer.
    static func shareText(_ slots: [DateInterval], now: Date, cal: Calendar) -> String? {
        guard let first = slots.first else { return nil }
        let rest = slots.dropFirst().map { span($0, now: now, cal: cal) }
        var text = "How about \(span(first, now: now, cal: cal))?"
        if !rest.isEmpty { text += " " + rest.joined(separator: " or ") + " works too." }
        return text
    }

    /// "Tue 2 PM works for me. See you there!"
    static func confirmText(_ start: Date, now: Date, cal: Calendar) -> String {
        "\(day(start, now: now, cal: cal)) \(clock(start, cal: cal, meridiem: true)) works for me. See you there!"
    }

    /// How the confirm line joins what is already typed, as its own sentence. "coffee with Ana at 3:30pm " drops the
    /// space and gets ". "; after a stop, comma or emoji, a space; at the start or after a new line, nothing.
    static func newSentence(after before: String) -> (drop: String, prefix: String) {
        guard let last = before.last(where: { !$0.isWhitespace }) else { return ("", "") }
        let tail = String(before.reversed().prefix { $0.isWhitespace && !$0.isNewline }.reversed())
        if before.dropLast(tail.count).last?.isNewline == true { return ("", "") }
        if !(last.isLetter || last.isNumber) { return ("", tail.isEmpty ? " " : "") }
        return (tail, ". ")
    }

    /// "Tue 17, 3:30-4:30 PM"
    static func whenText(_ i: DateInterval, cal: Calendar) -> String {
        format("EEE d", i.start, cal) + ", " + range(i, cal: cal)
    }

    /// "Tue 3:00 PM" for a Try instead chip; "2:00 PM" on the same day as `sameDayAs`.
    static func chipText(_ d: Date, sameDayAs: Date, cal: Calendar) -> String {
        format(cal.isDate(d, inSameDayAs: sameDayAs) ? "h:mm a" : "EEE h:mm a", d, cal)
    }

    /// The one quiet Pip line under the month. Today: the next event, with an offer to be reminded.
    /// Another day: its first free time, or that it is full.
    static func line(_ events: [Appointment], on day: Date, now: Date, cal: Calendar) -> String {
        let dayEvents = events.filter { cal.isDate($0.start, inSameDayAs: day) }
        if cal.isDate(day, inSameDayAs: now), let next = dayEvents.sorted(by: { $0.start < $1.start }).first(where: { $0.start > now }) {
            return "\(next.title) at \(clock(next.start, cal: cal, meridiem: true))."
        }
        if day < cal.startOfDay(for: now) { return dayEvents.isEmpty ? "Nothing was on this day." : "\(dayEvents.count) event\(dayEvents.count == 1 ? "" : "s") this day." }
        if let g = freeGaps(events, on: day, now: now, cal: cal).first {
            return "Free \(range(g, cal: cal)) \(cal.isDate(day, inSameDayAs: now) ? "today" : format("EEE", day, cal))."
        }
        return "\(cal.isDate(day, inSameDayAs: now) ? "Today" : format("EEEE", day, cal)) is full."
    }

    /// The month's cells, whole weeks from the locale's first weekday: 35 or 42 days, some from the months either side.
    static func monthGrid(_ month: Date, cal: Calendar) -> [Date] {
        guard let first = cal.dateInterval(of: .month, for: month)?.start,
              let days = cal.range(of: .day, in: .month, for: first)?.count else { return [] }
        let lead = (cal.component(.weekday, from: first) - cal.firstWeekday + 7) % 7
        let cells = Int(((Double(lead + days)) / 7).rounded(.up)) * 7
        return (0..<cells).compactMap { cal.date(byAdding: .day, value: $0 - lead, to: first) }
    }

    // MARK: formatting

    /// "Tue", or "Nov 25" a week or more away, so a weekday never means two dates.
    static func day(_ d: Date, now: Date, cal: Calendar) -> String {
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: d)).day ?? 0
        return format(days >= 0 && days < 7 ? "EEE" : "MMM d", d, cal)
    }

    private static func span(_ i: DateInterval, now: Date, cal: Calendar) -> String {
        "\(day(i.start, now: now, cal: cal)) \(range(i, cal: cal))"
    }

    /// "12:30-2 PM", "11:30 AM-1 PM": the AM/PM shows once when both ends share it.
    static func range(_ i: DateInterval, cal: Calendar) -> String {
        let same = format("a", i.start, cal) == format("a", i.end, cal)
        return clock(i.start, cal: cal, meridiem: !same) + "-" + clock(i.end, cal: cal, meridiem: true)
    }

    /// "2 PM", "12:30", "3:30 PM".
    static func clock(_ d: Date, cal: Calendar, meridiem: Bool) -> String {
        let whole = cal.component(.minute, from: d) == 0
        return format((whole ? "h" : "h:mm") + (meridiem ? " a" : ""), d, cal)
    }

    private static func format(_ pattern: String, _ d: Date, _ cal: Calendar) -> String {
        let f = DateFormatter()
        f.calendar = cal
        f.timeZone = cal.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = pattern
        return f.string(from: d)
    }

    private static func roundUp(_ d: Date, cal: Calendar) -> Date {
        let m = cal.component(.minute, from: d), s = cal.component(.second, from: d)
        let add = (30 - m % 30) % 30
        if add == 0 && s == 0 { return d }
        return cal.date(byAdding: .minute, value: add == 0 ? 30 : add, to: d.addingTimeInterval(-Double(s)))!
    }

    /// To the half hour, but never before `floor`.
    private static func roundDown(_ d: Date, floor: Date, cal: Calendar) -> Date {
        let m = cal.component(.minute, from: d), s = cal.component(.second, from: d)
        let r = d.addingTimeInterval(-Double((m % 30) * 60 + s))
        return r < floor ? floor : r
    }
}
