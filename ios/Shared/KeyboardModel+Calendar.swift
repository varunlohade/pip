import Foundation

/// The calendar panel: a month beside the chosen day, New event and Share a time. It reads and writes the phone's
/// calendar through `deps.writer`, which needs Full Access in the keyboard and the app's calendar permission.
struct CalendarPanel: Equatable {
    enum Screen: Equatable {
        case month
        case newEvent(NewEvent)
        /// The exact words Insert puts in the message. Nil: no free time to offer.
        case share(String?)
    }

    /// The first day of the month on screen.
    var month: Date
    /// Midnight of the chosen day.
    var selected: Date
    /// The events of the month on screen and the week after the chosen day. Nil: the keyboard may not read the calendar.
    var events: [Appointment]?
    var screen: Screen = .month
    /// What the last Add or Remind me did, with Undo for a few seconds.
    var done: CalendarDone?
}

struct NewEvent: Equatable {
    let title: String
    var when: DateInterval
    /// The event the wanted time overlaps.
    var clash: Appointment?
    /// Free starts for the same length: "2:00 PM", "Wed 3:00 PM".
    var tryInstead: [Date] = []
    /// Also put the confirm line in the message.
    var alsoMessage = true
    var message: String
}

struct CalendarDone: Equatable {
    let line: String
    let item: SmartAdded.Item
    /// The words Add also put in the message, so Undo can take them out.
    let inserted: String?
    /// The spaces Add took off the end of the message to close the typed plan with a full stop. Undo puts them back.
    var dropped = ""
}

extension KeyboardModel {
    private var cal: Calendar { .current }

    func toggleCalendar() {
        if calendar == nil { openCalendar() } else { host?.playClick(); closeCalendar() }
    }

    func openCalendar() {
        forgetIfAccountChanged()
        host?.playClick()
        notesOpen = false
        writeOpen = false
        closeExplain()
        let today = cal.startOfDay(for: deps.now())
        calendar = CalendarPanel(month: firstOfMonth(today), selected: today)
        loadCalendar()
    }

    func closeCalendar() {
        calendarUndoTask?.cancel()
        calendar = nil
    }

    /// The access the keyboard has to the calendar, for the panel's one line when it cannot read or write.
    var calendarAccess: SmartAccess { deps.writer.access(.calendar, hasFullAccess: hasFullAccess) }

    func selectDay(_ day: Date) {
        guard var c = calendar else { return }
        host?.playClick()
        c.selected = cal.startOfDay(for: day)
        c.month = firstOfMonth(day)
        c.screen = .month
        calendar = c
        loadCalendar()
    }

    /// ‹ and ›: the month before or after. The chosen day moves to today in that month, else to its first day.
    func showMonth(by offset: Int) {
        guard var c = calendar, let m = cal.date(byAdding: .month, value: offset, to: c.month) else { return }
        host?.playClick()
        let today = cal.startOfDay(for: deps.now())
        c.month = m
        c.selected = cal.isDate(today, equalTo: m, toGranularity: .month) ? today : m
        calendar = c
        loadCalendar()
    }

    func calendarBack() {
        guard var c = calendar else { return }
        host?.playClick()
        c.screen = .month
        calendar = c
    }

    /// "+": a new event on the chosen day. A plan typed in the field ("coffee with Ana tue 3:30pm") gives the title and time.
    func startNewEvent() {
        guard var c = calendar else { return }
        host?.playClick()
        let now = deps.now()
        let typedPlan = SmartDetect.detect(typed, now: now).lazy.compactMap { chip -> (String, Date, Date)? in
            if case .event(let t, let s, let e?) = chip.action { return (t, s, e) }
            return nil
        }.first
        let when: DateInterval
        if let p = typedPlan {
            when = DateInterval(start: p.1, end: p.2)
        } else {
            let isToday = cal.isDate(c.selected, inSameDayAs: now)
            let start = isToday ? nextHour(now) : cal.date(bySettingHour: 12, minute: 0, second: 0, of: c.selected)!
            when = DateInterval(start: start, duration: 3600)
        }
        c.selected = cal.startOfDay(for: when.start)
        c.month = firstOfMonth(when.start)
        calendar = c
        loadCalendar()
        calendar?.screen = .newEvent(planned(title: typedPlan?.0 ?? "New event", when: when, alsoMessage: true))
    }

    /// A Try instead chip: the same length at that start.
    func pickTime(_ start: Date) {
        guard case .newEvent(let e)? = calendar?.screen else { return }
        host?.playClick()
        let when = DateInterval(start: start, duration: e.when.duration)
        if !cal.isDate(start, inSameDayAs: calendar!.selected) {
            calendar?.selected = cal.startOfDay(for: start)
            calendar?.month = firstOfMonth(start)
            loadCalendar()
        }
        calendar?.screen = .newEvent(planned(title: e.title, when: when, alsoMessage: e.alsoMessage))
    }

    func toggleAlsoMessage() {
        guard case .newEvent(var e)? = calendar?.screen else { return }
        host?.playClick()
        e.alsoMessage.toggle()
        calendar?.screen = .newEvent(e)
    }

    /// Add: the event goes in the calendar, and the confirm line in the message when ticked. Undo takes both back.
    func addNewEvent() {
        guard var c = calendar, case .newEvent(let e) = c.screen, calendarAccess == .ready else { return }
        host?.playClick()
        let id: String
        do { id = try deps.writer.addEvent(title: e.title, start: e.when.start, end: e.when.end) } catch {
            c.done = nil
            calendar = c
            bar = .error("Could not add that. Try again.")
            return
        }
        var inserted: String?
        var dropped = ""
        if e.alsoMessage {
            let join = CalendarPlan.newSentence(after: host?.contextBeforeInput ?? "")
            for _ in 0..<join.drop.count { host?.deleteBackward() }
            let text = join.prefix + e.message
            host?.insert(text)
            inserted = text
            dropped = join.drop
            updateAutoShift()
        }
        c.screen = .month
        c.selected = cal.startOfDay(for: e.when.start)
        c.month = firstOfMonth(e.when.start)
        c.done = CalendarDone(line: "Added \(e.title), \(CalendarPlan.day(e.when.start, now: deps.now(), cal: cal)) \(CalendarPlan.clock(e.when.start, cal: cal, meridiem: true)).",
                              item: .event(id), inserted: inserted, dropped: dropped)
        calendar = c
        loadCalendar()
        startCalendarUndoWindow()
    }

    /// "Remind me?" on today's next event: a reminder 15 minutes before it.
    func remindBeforeNext() {
        guard let c = calendar, let next = nextEventToday(c),
              deps.writer.access(.reminders, hasFullAccess: hasFullAccess) == .ready else { return }
        host?.playClick()
        let due = next.start.addingTimeInterval(-15 * 60)
        guard let id = try? deps.writer.addReminder(title: next.title, due: due) else { bar = .error("Could not add that. Try again."); return }
        calendar?.done = CalendarDone(line: "I'll remind you at \(CalendarPlan.clock(due, cal: cal, meridiem: true)).", item: .reminder(id), inserted: nil)
        startCalendarUndoWindow()
    }

    func undoCalendarDone() {
        guard let d = calendar?.done else { return }
        host?.playClick()
        calendarUndoTask?.cancel()
        switch d.item {
        case .event(let id): try? deps.writer.removeEvent(id)
        case .reminder(let id): try? deps.writer.removeReminder(id)
        case .note: break
        }
        if let text = d.inserted, (host?.contextBeforeInput ?? "").hasSuffix(text) {
            for _ in 0..<text.count { host?.deleteBackward() }
            if !d.dropped.isEmpty { host?.insert(d.dropped) }
            updateAutoShift()
        }
        calendar?.done = nil
        loadCalendar()
    }

    /// Share a time: the exact words first. Nothing goes in until Insert.
    func startShare() {
        guard var c = calendar else { return }
        host?.playClick()
        let now = deps.now()
        let from = c.selected
        if let events = deps.writer.events(from: cal.startOfDay(for: max(from, now)), to: cal.date(byAdding: .day, value: 8, to: max(from, now))!, hasFullAccess: hasFullAccess) {
            c.screen = .share(CalendarPlan.shareText(CalendarPlan.shareSlots(events, from: from, now: now, cal: cal), now: now, cal: cal))
        } else {
            c.screen = .share(nil)
        }
        calendar = c
    }

    func insertShare() {
        guard case .share(let text?)? = calendar?.screen else { return }
        host?.playClick()
        let before = host?.contextBeforeInput ?? ""
        host?.insert((before.isEmpty || before.last?.isWhitespace == true ? "" : " ") + text)
        closeCalendar()
        updateAutoShift()
    }

    /// "Ask Pip anything": the keys come back, so the question is typed in the message, where Pip answers it.
    func askFromCalendar() {
        host?.playClick()
        closeCalendar()
    }

    /// Today's next event, for the Pip line's "Remind me?".
    func nextEventToday(_ c: CalendarPanel) -> Appointment? {
        let now = deps.now()
        guard cal.isDate(c.selected, inSameDayAs: now) else { return nil }
        return c.events?.first { $0.start > now && cal.isDate($0.start, inSameDayAs: now) }
    }

    // MARK: private

    /// Reads the month on screen and the week after the chosen day.
    private func loadCalendar() {
        guard var c = calendar else { return }
        let grid = CalendarPlan.monthGrid(c.month, cal: cal)
        guard let first = grid.first, let last = grid.last,
              let weekOn = cal.date(byAdding: .day, value: 8, to: c.selected) else { return }
        c.events = deps.writer.events(from: min(first, c.selected), to: max(cal.date(byAdding: .day, value: 1, to: last)!, weekOn), hasFullAccess: hasFullAccess)
        calendar = c
    }

    private func planned(title: String, when: DateInterval, alsoMessage: Bool) -> NewEvent {
        let now = deps.now()
        let events = calendar?.events ?? []
        let clash = CalendarPlan.clash(when, with: events)
        let tryInstead = clash == nil ? [] : CalendarPlan.alternatives(for: when, events: events, now: now, cal: cal)
        return NewEvent(title: title, when: when, clash: clash, tryInstead: tryInstead, alsoMessage: alsoMessage,
                        message: CalendarPlan.confirmText(when.start, now: now, cal: cal))
    }

    private func startCalendarUndoWindow() {
        calendarUndoTask?.cancel()
        let sleep = deps.sleep
        calendarUndoTask = Task { [weak self] in
            try? await sleep(Self.undoWindow)
            guard !Task.isCancelled else { return }
            self?.calendar?.done = nil
        }
    }

    private func firstOfMonth(_ d: Date) -> Date { cal.dateInterval(of: .month, for: d)?.start ?? d }

    private func nextHour(_ d: Date) -> Date {
        let h = cal.dateInterval(of: .hour, for: d)?.start ?? d
        return cal.date(byAdding: .hour, value: 1, to: h) ?? d
    }
}
