import Foundation

/// A device action read from typed text. `trigger` is the exact words that caused it, shown quoted on the chip.
struct SmartChip: Equatable, Hashable {
    enum Action: Equatable, Hashable {
        /// `end` nil: an all-day event (the text named a day but no time).
        case event(title: String, start: Date, end: Date?)
        case reminder(title: String, due: Date)
        case note(text: String)
    }

    enum Place: Equatable { case calendar, reminders, notes }

    let action: Action
    let trigger: String

    var place: Place {
        switch action {
        case .event: .calendar
        case .reminder: .reminders
        case .note: .notes
        }
    }

    var id: String {
        switch action {
        case .event: "smart.event"
        case .reminder: "smart.reminder"
        case .note: "smart.note"
        }
    }

    /// The same chip read again later: same kind, same trigger words, though a relative time ("in 20 min") moved on.
    func sameReading(as other: SmartChip) -> Bool { id == other.id && trigger == other.trigger }

    /// "Add to calendar · Tue 3:00 PM", "Remind me 5:00 PM", "Save note".
    func label(now: Date, calendar cal: Calendar = .current) -> String {
        switch action {
        case .event(_, let start, let end): "Add to calendar \u{00B7} " + SmartDetect.when(start, allDay: end == nil, now: now, cal: cal)
        case .reminder(_, let due): "Remind me " + SmartDetect.when(due, allDay: false, now: now, cal: cal, todayBare: true)
        case .note: "Save note"
        }
    }

    /// The action alone, for beside the trigger, which already says when.
    var shortLabel: String {
        switch action {
        case .event: "Add to calendar"
        case .reminder: "Remind me"
        case .note: "Save note"
        }
    }

    /// The bar's line after one tap added it.
    func doneLabel(now: Date, calendar cal: Calendar = .current) -> String {
        switch action {
        case .event(_, let start, let end): "Added to Calendar \u{00B7} " + SmartDetect.when(start, allDay: end == nil, now: now, cal: cal) + " \u{2713}"
        case .reminder(_, let due): "Reminder set \u{00B7} " + SmartDetect.when(due, allDay: false, now: now, cal: cal, todayBare: true) + " \u{2713}"
        case .note: "Saved to Notes \u{2713}"
        }
    }
}

/// Reads events, reminders and notes out of what the owner types, on the phone, with no model call.
/// NSDataDetector finds dates; a few regexes find the task words and the times it misses ("at 5", "in 20 min").
/// Pure apart from NSDataDetector, which reads relative days ("tomorrow") against the real clock.
enum SmartDetect {
    static let maxChips = 3

    static func detect(_ text: String, now: Date, calendar cal: Calendar = .current) -> [SmartChip] {
        let s = lastSentence(text)
        guard !s.isEmpty, !s.hasPrefix(SuggestPolicy.shortcutPrefix), SecretScan.scan(s) == .clean else { return [] }
        var out: [SmartChip] = []
        if let w = findWhen(s, now: now, cal: cal) {
            let trigger = String(s[w.range])
            let reminderFirst = s.range(of: #"^\W*(?:please\s+)?remind me\b"#, options: [.regularExpression, .caseInsensitive]) != nil
            if !reminderFirst, has(s, meetingWords) {
                let title = cleanTitle(s, removing: w.range, fallback: "Event")
                let end = w.hasTime ? w.date.addingTimeInterval(3600) : nil
                out.append(SmartChip(action: .event(title: title, start: w.date, end: end), trigger: trigger))
            } else if reminderFirst || has(s, taskWords) {
                let due = w.hasTime ? w.date : cal.date(bySettingHour: 9, minute: 0, second: 0, of: w.date) ?? w.date
                out.append(SmartChip(action: .reminder(title: cleanTitle(s, removing: w.range, fallback: "Reminder"), due: due), trigger: trigger))
            }
        } else if let r = s.range(of: notePattern, options: [.regularExpression, .caseInsensitive]) {
            let body = cleanTitle(s, removing: nil, fallback: "")
            if !body.isEmpty { out.append(SmartChip(action: .note(text: body), trigger: s[r].trimmingCharacters(in: .whitespaces.union(.punctuationCharacters)))) }
        }
        return Array(out.prefix(maxChips))
    }

    /// Text with action-ish signals and no clear match: a task word, a time or number, a name, a question.
    /// Only this kind of text may go to the server, once per sentence; plain chat never does.
    static func maybe(_ text: String) -> Bool {
        let s = lastSentence(text)
        guard s.split(whereSeparator: \.isWhitespace).count >= SuggestPolicy.minWords, SecretScan.scan(s) == .clean else { return false }
        let words = s.split(whereSeparator: \.isWhitespace)
        let name = words.dropFirst().contains { w in w.first?.isUppercase == true && w.count > 1 && w.dropFirst().contains(where: \.isLowercase) }
        return has(s, taskWords) || has(s, meetingWords) || s.contains(where: \.isNumber) || name || s.hasSuffix("?")
    }

    // MARK: parts

    struct When { let date: Date; let hasTime: Bool; let range: Range<String.Index> }

    static let taskWords = #"\b(?:remind|call|ring|text|email|buy|pick up|send|pay|order|book|check|follow up|don'?t forget|do not forget|need to|todo|to-?do)\b"#
    static let meetingWords = #"\b(?:meeting|meet|appointment|appt|dentist|doctor|lunch|dinner|breakfast|coffee|drinks|interview|haircut|session|class|party|flight|call with|catch up|demo|visit|consult\w*)\b"#
    static let notePattern = #"^\W*(?:(?:note|todo|to-?do|to do)\b\s*[:\-]?|(?:i\s+)?need to\s+(?:buy|get|grab|order|pick up)\b|don'?t forget(?:\s+to)?\b)"#
    private static let markers = #"\b(?:am|pm|a\.m\.|p\.m\.|noon|midnight|tonight|morning|afternoon|evening|night)\b"#
    private static let dayWords = #"\b(?:today|tonight|tomorrow|mon|tue|wed|thu|fri|sat|sun)\w*|\d{1,2}[/.-]\d{1,2}|\b(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)\w*\s+\d"#

    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)

    static func lastSentence(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // A sentence ends at . ! ? or a new line, then space. "3:30" and "p.m." stay whole.
        let parts = t.components(separatedBy: "\n").last ?? t
        guard let r = parts.range(of: #"[.!?]\s+(?=\S)(?!.*[.!?]\s+\S)"#, options: .regularExpression) else { return parts }
        return String(parts[r.upperBound...]).trimmingCharacters(in: .whitespaces)
    }

    static func has(_ s: String, _ pattern: String) -> Bool {
        s.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func findWhen(_ s: String, now: Date, cal: Calendar) -> When? {
        // "in 20 min", "in an hour": from now.
        if let r = s.range(of: #"\bin\s+(\d+|an?|half an?)\s*(minutes?|mins?|m|hours?|hrs?|h)\b"#, options: [.regularExpression, .caseInsensitive]) {
            let m = s[r].lowercased()
            let n = Double(m.filter(\.isNumber)) ?? (m.contains("half") ? 0.5 : 1)
            let unit: Double = m.range(of: #"\d*\s*(hours?|hrs?|h)\b"#, options: .regularExpression) != nil ? 3600 : 60
            return When(date: now.addingTimeInterval(n * unit), hasTime: true, range: r)
        }
        if let match = detector?.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), var date = match.date, let r = Range(match.range, in: s) {
            let words = String(s[r])
            let hasTime = words.contains(where: \.isNumber) || has(words, markers)
            let marked = has(words, markers)
            // A bare 1 to 7 o'clock is afternoon for a business: "pick up kids at 3:30".
            let hour = cal.component(.hour, from: date)
            if hasTime, !marked, (1...7).contains(hour) { date = date.addingTimeInterval(12 * 3600) }
            if hasTime, !has(words, dayWords) { date = rollForward(date, now: now, marked: marked) }
            // "at 5pm", "on Tuesday": the little word before belongs to the time.
            let lead = s[..<r.lowerBound].range(of: #"\b(?:at|by|on|@)\s*$"#, options: [.regularExpression, .caseInsensitive])
            return When(date: date, hasTime: hasTime, range: (lead?.lowerBound ?? r.lowerBound)..<r.upperBound)
        }
        // "at 5", "by 6:30": NSDataDetector misses a bare hour.
        if let r = s.range(of: #"\b(?:at|by|@)\s*(\d{1,2})(?::(\d{2}))?\b(?!\s*(?:%|[$€£]|dollars|bucks|min|hours?|people|pax))"#, options: [.regularExpression, .caseInsensitive]) {
            let digits = s[r].drop { !$0.isNumber }.split(separator: ":")
            guard let h = Int(digits[0]), h <= 23 else { return nil }
            let mm = digits.count > 1 ? Int(digits[1]) ?? 0 : 0
            let hour = (1...7).contains(h) ? h + 12 : h
            guard let date = cal.date(bySettingHour: hour, minute: mm, second: 0, of: now) else { return nil }
            return When(date: rollForward(date, now: now, marked: h > 12), hasTime: true, range: r)
        }
        return nil
    }

    /// A time with no day that has passed today: later today if 12 hours on fits ("dinner at 8" at 4 PM), else tomorrow.
    static func rollForward(_ date: Date, now: Date, marked: Bool) -> Date {
        guard date < now else { return date }
        let pm = date.addingTimeInterval(12 * 3600)
        if !marked, Calendar.current.component(.hour, from: date) < 12, pm > now, Calendar.current.isDate(pm, inSameDayAs: date) { return pm }
        return date.addingTimeInterval(86_400)
    }

    /// The text without the time words, the lead-in ("remind me to"), the amount and the loose ends. "Meeting with Ana".
    static func cleanTitle(_ s: String, removing range: Range<String.Index>?, fallback: String) -> String {
        var t = s
        if let range { t.replaceSubrange(range, with: " ") }
        let cuts = [
            #"^\W*(?:hey\s+)?(?:please\s+)?(?:remind me(?:\s+to)?|don'?t forget(?:\s+to)?|do not forget(?:\s+to)?|(?:i\s+)?need to|note\b\s*[:\-]?|to-?do\b\s*[:\-]?|to do\b\s*[:\-]?)\s*"#,
            #"(?:[$€£]\s?\d+(?:[.,]\d{1,2})?|\b\d+(?:[.,]\d{1,2})?\s?(?:[$€£]|usd|eur|gbp|dollars?|bucks|euros?)\b)(?:\s+for\b)?"#,
            #"\b(?:today|tonight|tomorrow)\b"#,
        ]
        for c in cuts { t = t.replacingOccurrences(of: c, with: " ", options: [.regularExpression, .caseInsensitive]) }
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces.union(.punctuationCharacters))
        // Loose ends left by the cuts: "remind me to", "on", "the".
        for _ in 0..<3 {
            t = t.replacingOccurrences(of: #"^(?:to|the|a|an|my|and)\s+|\s+(?:on|at|by|for|this|next|in|from|to|and)$"#, with: "", options: [.regularExpression, .caseInsensitive])
                .trimmingCharacters(in: .whitespaces.union(.punctuationCharacters))
        }
        guard let first = t.first else { return fallback }
        return first.uppercased() + t.dropFirst()
    }

    /// "Tue 3:00 PM", "Thu" (all day), or "5:00 PM" for a reminder later today.
    static func when(_ date: Date, allDay: Bool, now: Date, cal: Calendar, todayBare: Bool = false) -> String {
        let f = DateFormatter()
        f.calendar = cal
        f.timeZone = cal.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = allDay ? "EEE" : (todayBare && cal.isDate(date, inSameDayAs: now) ? "h:mm a" : "EEE h:mm a")
        return f.string(from: date)
    }
}
