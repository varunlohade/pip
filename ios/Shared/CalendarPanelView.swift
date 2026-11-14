import SwiftUI

/// Calendar design C (design/calendar/C.png, C-2.png): the month beside the chosen day, one Pip line, then Ask and
/// Share a time. New event and Share a time take the same space.
struct CalendarPanelView: View {
    @ObservedObject var model: KeyboardModel
    let panel: CalendarPanel
    let palette: Theme.SystemKeyboard.Palette

    var body: some View {
        Group {
            switch panel.screen {
            case .month: MonthScreen(model: model, panel: panel, palette: palette)
            case .newEvent(let e): NewEventScreen(model: model, panel: panel, event: e, palette: palette)
            case .share(let text): ShareScreen(model: model, text: text, palette: palette)
            }
        }
        .padding(.horizontal, 7)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// The bar while the calendar is open: the month and its arrows, + and the keys; or Back and the screen's name.
/// The globe joins them when iOS draws none (Home button phones such as the SE).
struct CalendarBar: View {
    @ObservedObject var model: KeyboardModel
    let panel: CalendarPanel
    let palette: Theme.SystemKeyboard.Palette

    var body: some View {
        HStack(spacing: 0) {
            switch panel.screen {
            case .month:
                Text(CalendarStyle.monthTitle(panel.month, now: model.deps.now()))
                    .font(.system(size: 17, weight: .semibold)).foregroundStyle(palette.label)
                    .lineLimit(1).fixedSize()
                    .padding(.leading, 8)
                    .accessibilityAddTraits(.isHeader)
                icon("chevron.left", id: "calendar.prev", label: "Previous month", small: true) { model.showMonth(by: -1) }
                icon("chevron.right", id: "calendar.next", label: "Next month", small: true) { model.showMonth(by: 1) }
                Spacer(minLength: 0)
                icon("plus", id: "calendar.add", label: "New event") { model.startNewEvent() }
            case .newEvent, .share:
                icon("chevron.left", id: "calendar.back", label: "Back to the month") { model.calendarBack() }
                Text(isShare ? "Share a time" : "New event").font(.system(size: 17, weight: .semibold)).foregroundStyle(palette.label)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
            }
            if model.host?.needsGlobeKey == true {
                icon("globe", id: "calendar.globe", label: "Next keyboard") { model.host?.nextKeyboard() }
            }
            icon("keyboard", id: "calendar.close", label: "Keyboard") { model.toggleCalendar() }
        }
        .padding(.horizontal, 4)
    }

    private var isShare: Bool { if case .share = panel.screen { return true }; return false }

    private func icon(_ name: String, id: String, label: String, small: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: small ? 15 : 19, weight: small ? .semibold : .regular)).foregroundStyle(palette.label)
                .frame(width: small ? 32 : 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }
}

/// Colors and words the three screens share. Sky is the only loud color.
enum CalendarStyle {
    static func card(_ p: Theme.SystemKeyboard.Palette) -> Color { p.key }
    static func free(_ dark: Bool) -> Color { dark ? Theme.Color.sky : Theme.Color.skyDeep }
    static func warn(_ dark: Bool) -> Color { dark ? Color(hex: 0xFF8A5C) : Theme.Color.warning }
    static func ice(_ dark: Bool) -> Color { dark ? Theme.Color.sky.opacity(0.22) : Theme.Color.ice }
    static func faint(_ p: Theme.SystemKeyboard.Palette) -> Color { p.secondaryLabel.opacity(0.75) }

    static func format(_ pattern: String, _ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = pattern
        return f.string(from: d)
    }

    /// "November", or "January 2027" outside this year.
    static func monthTitle(_ month: Date, now: Date) -> String {
        format(Calendar.current.isDate(month, equalTo: now, toGranularity: .year) ? "MMMM" : "MMMM yyyy", month)
    }
}

/// The sky pill and the white pill at the bottom of each screen. 44 pt tall, no glow.
private struct PanelButton: View {
    let title: String
    var accent = false
    let palette: Theme.SystemKeyboard.Palette
    let id: String
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 16, weight: .semibold))
                .foregroundStyle(accent ? .white : palette.label)
                .lineLimit(1).minimumScaleFactor(0.8)
                .padding(.horizontal, 18)
                .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44)
                .background(accent ? Theme.Color.sky : palette.key, in: Capsule())
                .shadow(color: .black.opacity(accent ? 0.12 : 0.18), radius: 0, y: 1)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityIdentifier(id)
    }
}

/// One quiet line from Pip: the buddy, plain words, and at most one offer.
private struct PipLine: View {
    struct Offer {
        let title: String, id: String, label: String
        let action: () -> Void
    }
    let text: String
    var offer: Offer?
    let palette: Theme.SystemKeyboard.Palette
    let dark: Bool

    var body: some View {
        HStack(spacing: 7) {
            Buddy(size: 17)
            Text(text).font(.system(size: 14)).foregroundStyle(palette.secondaryLabel)
                .lineLimit(1).minimumScaleFactor(0.8)
            if let o = offer {
                Button(action: o.action) {
                    Text(o.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(CalendarStyle.free(dark))
                        .fixedSize().frame(minHeight: 32).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(o.label)
                .accessibilityIdentifier(o.id)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 32)
        .padding(.horizontal, 4)
        .accessibilityElement(children: .contain)
    }
}

// MARK: month beside the day

private struct MonthScreen: View {
    @ObservedObject var model: KeyboardModel
    let panel: CalendarPanel
    let palette: Theme.SystemKeyboard.Palette
    private let cal = Calendar.current

    var body: some View {
        let now = model.deps.now()
        VStack(spacing: 0) {
            GeometryReader { geo in
                HStack(alignment: .top, spacing: 10) {
                    MonthGrid(model: model, panel: panel, palette: palette, now: now)
                        .frame(width: min(184, (geo.size.width - 10) * 0.49))
                    DayCard(model: model, panel: panel, palette: palette, now: now)
                }
            }
            .frame(height: 174)
            .padding(.top, 2)
            line(now)
                .padding(.top, 4)
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Button(action: model.askFromCalendar) {
                    HStack(spacing: 8) {
                        Buddy(size: 22)
                        Text("Ask Pip anything").font(.system(size: 15)).foregroundStyle(CalendarStyle.faint(palette)).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, 9).padding(.trailing, 14)
                    .frame(height: 44)
                    .background(palette.key, in: Capsule())
                    .shadow(color: .black.opacity(0.16), radius: 0, y: 1)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Ask Pip anything")
                .accessibilityHint("Shows the keys. Type your question in the message.")
                .accessibilityIdentifier("calendar.ask")
                PanelButton(title: "Share a time", accent: true, palette: palette, id: "calendar.share", action: model.startShare)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
    }

    private var remindOffer: PipLine.Offer? {
        guard model.nextEventToday(panel) != nil,
              model.deps.writer.access(.reminders, hasFullAccess: model.hasFullAccess) == .ready else { return nil }
        return PipLine.Offer(title: "Remind me?", id: "calendar.remind", label: "Remind me 15 minutes before", action: model.remindBeforeNext)
    }

    @ViewBuilder
    private func line(_ now: Date) -> some View {
        let dark = model.isDark
        if let d = panel.done {
            PipLine(text: d.line, offer: PipLine.Offer(title: "Undo", id: "calendar.undo", label: "Undo", action: model.undoCalendarDone), palette: palette, dark: dark)
        } else if let events = panel.events {
            PipLine(text: CalendarPlan.line(events, on: panel.selected, now: now, cal: cal), offer: remindOffer, palette: palette, dark: dark)
        } else {
            PipLine(text: model.calendarAccess == .needsFullAccess ? "Turn on Full Access to see your calendar." : "Open Pip to connect your calendar.",
                    palette: palette, dark: dark)
        }
    }
}

private struct MonthGrid: View {
    @ObservedObject var model: KeyboardModel
    let panel: CalendarPanel
    let palette: Theme.SystemKeyboard.Palette
    let now: Date
    private let cal = Calendar.current

    var body: some View {
        let cells = CalendarPlan.monthGrid(panel.month, cal: cal)
        let rows = cells.count / 7
        let busy = Set((panel.events ?? []).map { cal.startOfDay(for: $0.start) })
        let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)
        VStack(spacing: 2) {
            LazyVGrid(columns: columns, spacing: 0) {
                ForEach(Array(weekdayLetters.enumerated()), id: \.offset) { _, l in
                    Text(l).font(.system(size: 10.5, weight: .medium)).foregroundStyle(CalendarStyle.faint(palette))
                        .frame(height: 14)
                        .accessibilityHidden(true)
                }
            }
            LazyVGrid(columns: columns, spacing: rows > 5 ? 0 : 1) {
                ForEach(cells, id: \.self) { day in
                    cell(day, busy: busy.contains(day), height: rows > 5 ? 26 : 27)
                }
            }
        }
        .gesture(DragGesture(minimumDistance: 24).onEnded { v in
            if abs(v.translation.width) > abs(v.translation.height) { model.showMonth(by: v.translation.width < 0 ? 1 : -1) }
        })
    }

    private var weekdayLetters: [String] {
        let s = cal.veryShortStandaloneWeekdaySymbols
        let first = cal.firstWeekday - 1
        return Array(s[first...] + s[..<first])
    }

    private func cell(_ day: Date, busy: Bool, height: CGFloat) -> some View {
        let inMonth = cal.isDate(day, equalTo: panel.month, toGranularity: .month)
        let selected = cal.isDate(day, inSameDayAs: panel.selected)
        let today = cal.isDate(day, inSameDayAs: now)
        let n = cal.component(.day, from: day)
        let count = (panel.events ?? []).filter { cal.isDate($0.start, inSameDayAs: day) }.count
        return Button { model.selectDay(day) } label: {
            ZStack {
                if selected { Circle().fill(Theme.Color.sky).frame(width: 25, height: 25) }
                Text("\(n)").font(.system(size: 14, weight: selected || today ? .semibold : .regular)).monospacedDigit()
                    .foregroundStyle(selected ? .white : today ? CalendarStyle.free(model.isDark) : inMonth ? palette.label : CalendarStyle.faint(palette).opacity(0.7))
                if busy && !selected {
                    Circle().fill(palette.secondaryLabel.opacity(0.8)).frame(width: 4, height: 4)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
            .frame(maxWidth: .infinity).frame(height: height).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(CalendarStyle.format("EEEE, MMMM d", day) + (today ? ", today" : "") + (panel.events == nil ? "" : count == 0 ? ", nothing planned" : ", \(count) event\(count == 1 ? "" : "s")"))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(inMonth ? "calendar.day.\(n)" : "calendar.other.\(n)")
    }
}

private struct DayCard: View {
    @ObservedObject var model: KeyboardModel
    let panel: CalendarPanel
    let palette: Theme.SystemKeyboard.Palette
    let now: Date
    private let cal = Calendar.current

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text(CalendarStyle.format("EEEE d", panel.selected)).font(.system(size: 15, weight: .semibold)).foregroundStyle(palette.label)
                    .lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                if cal.isDate(panel.selected, inSameDayAs: now) {
                    Text("Today").font(.system(size: 13)).foregroundStyle(CalendarStyle.faint(palette))
                }
            }
            .padding(.leading, 4)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            if let events = panel.events {
                let rows = CalendarPlan.rows(events, on: panel.selected, now: now, cal: cal)
                if rows.isEmpty {
                    Text(panel.selected < cal.startOfDay(for: now) ? "Nothing was planned." : "Nothing planned.")
                        .font(.system(size: 14)).foregroundStyle(palette.secondaryLabel)
                } else {
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(rows) { row(for: $0) }
                        }
                    }
                }
            } else {
                Text("Your events show here once Pip can read your calendar.")
                    .font(.system(size: 14)).foregroundStyle(palette.secondaryLabel).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 10).padding(.leading, 8).padding(.trailing, 12).padding(.bottom, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(CalendarStyle.card(palette), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityIdentifier("calendar.dayCard")
    }

    @ViewBuilder
    private func row(for r: CalendarPlan.Row) -> some View {
        let dark = model.isDark
        switch r {
        case .event(let a, let past):
            HStack(spacing: 8) {
                time(a.start, color: palette.secondaryLabel)
                RoundedRectangle(cornerRadius: 1.5).fill(a.color.map { Color(hex: $0) } ?? Theme.Color.sky).frame(width: 3, height: 14)
                Text(a.title).font(.system(size: 14)).foregroundStyle(palette.label).lineLimit(1).truncationMode(.tail)
            }
            .frame(height: 23)
            .opacity(past ? 0.45 : 1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(CalendarPlan.range(DateInterval(start: a.start, end: max(a.start, a.end)), cal: cal)), \(a.title)\(past ? ", done" : "")")
        case .free(let g):
            HStack(spacing: 8) {
                time(g.start, color: CalendarStyle.free(dark))
                RoundedRectangle(cornerRadius: 1.5).strokeBorder(Theme.Color.sky, lineWidth: 1.2).frame(width: 3, height: 14)
                Text("Free until \(CalendarPlan.clock(g.end, cal: cal, meridiem: false))")
                    .font(.system(size: 14, weight: .medium)).foregroundStyle(CalendarStyle.free(dark)).lineLimit(1).minimumScaleFactor(0.85)
            }
            .frame(height: 23)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Free \(CalendarPlan.range(g, cal: cal))")
        }
    }

    private func time(_ d: Date, color: Color) -> some View {
        Text(CalendarStyle.format("h:mm", d)).font(.system(size: 13, weight: .medium)).monospacedDigit().foregroundStyle(color)
            .lineLimit(1).minimumScaleFactor(0.8)
            .frame(width: 38, alignment: .trailing)
    }
}

// MARK: New event

private struct NewEventScreen: View {
    @ObservedObject var model: KeyboardModel
    let panel: CalendarPanel
    let event: NewEvent
    let palette: Theme.SystemKeyboard.Palette
    private let cal = Calendar.current

    var body: some View {
        let dark = model.isDark
        let ready = model.calendarAccess == .ready
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 0) {
                field("Title") {
                    Text(event.title).font(.system(size: 16, weight: .medium)).foregroundStyle(palette.label).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                field("When") {
                    Text(CalendarPlan.whenText(event.when, cal: cal)).font(.system(size: 16)).foregroundStyle(palette.label)
                        .lineLimit(1).minimumScaleFactor(0.75)
                    Spacer(minLength: 6)
                    if let c = event.clash {
                        Text("busy: \(c.title)").font(.system(size: 14)).foregroundStyle(CalendarStyle.warn(dark))
                            .lineLimit(1).truncationMode(.tail)
                            .layoutPriority(-1)
                            .accessibilityLabel("Clash: you're busy with \(c.title)")
                            .accessibilityIdentifier("calendar.clash")
                    }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 4)
            .background(CalendarStyle.card(palette), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.top, 4)

            hint(dark: dark)
                .padding(.top, 8)

            Button(action: model.toggleAlsoMessage) {
                HStack(alignment: .top, spacing: 9) {
                    ZStack {
                        Circle().fill(event.alsoMessage ? Theme.Color.sky : .clear)
                        Circle().strokeBorder(event.alsoMessage ? .clear : palette.secondaryLabel, lineWidth: 1.5)
                        if event.alsoMessage { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white) }
                    }
                    .frame(width: 20, height: 20)
                    (Text("Also add to your message: ").foregroundColor(palette.secondaryLabel)
                        + Text("\u{201C}\(event.message)\u{201D}").foregroundColor(palette.label))
                        .font(.system(size: 14)).lineLimit(2).multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 2).padding(.top, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Also add to your message: \(event.message)")
            .accessibilityValue(event.alsoMessage ? "On" : "Off")
            .accessibilityAddTraits(.isToggle)
            .accessibilityIdentifier("calendar.also")

            Spacer(minLength: 0)
            // Cancel takes a third, Add the rest, as drawn.
            GeometryReader { geo in
                HStack(spacing: 8) {
                    PanelButton(title: "Cancel", palette: palette, id: "calendar.cancel", action: model.calendarBack)
                        .frame(width: (geo.size.width - 8) * 0.31)
                    PanelButton(title: "Add at \(CalendarPlan.chipText(event.when.start, sameDayAs: panel.selected, cal: cal))", accent: true,
                                palette: palette, id: "calendar.addEvent", enabled: ready, action: model.addNewEvent)
                }
            }
            .frame(height: 44)
        }
    }

    @ViewBuilder
    private func hint(dark: Bool) -> some View {
        if model.calendarAccess != .ready {
            PipLine(text: model.calendarAccess == .needsFullAccess ? "Turn on Full Access to add events." : "Open Pip to connect your calendar.", palette: palette, dark: dark)
        } else if panel.events == nil {
            PipLine(text: "I can't see your calendar, so no clash check.", palette: palette, dark: dark)
        } else if event.clash != nil, !event.tryInstead.isEmpty {
            HStack(spacing: 8) {
                Buddy(size: 17)
                Text("Try instead").font(.system(size: 14)).foregroundStyle(palette.secondaryLabel).lineLimit(1).fixedSize()
                ForEach(Array(event.tryInstead.enumerated()), id: \.offset) { i, d in
                    let title = CalendarPlan.chipText(d, sameDayAs: event.when.start, cal: cal)
                    Button { model.pickTime(d) } label: {
                        Text(title).font(.system(size: 14.5, weight: .medium)).monospacedDigit()
                            .foregroundStyle(i == 0 ? CalendarStyle.free(dark) : palette.label)
                            .lineLimit(1).fixedSize()
                            .padding(.horizontal, 12).frame(height: 32)
                            .background(i == 0 ? CalendarStyle.ice(dark) : palette.key, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Try \(CalendarStyle.format("EEEE h:mm a", d)) instead")
                    .accessibilityIdentifier("calendar.try.\(i)")
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 2)
        } else if event.clash != nil {
            PipLine(text: "No free time near then this week.", palette: palette, dark: dark)
        } else {
            PipLine(text: "You're free then.", palette: palette, dark: dark)
        }
    }

    private func field<V: View>(_ key: String, @ViewBuilder value: () -> V) -> some View {
        HStack(spacing: 10) {
            Text(key).font(.system(size: 14)).foregroundStyle(CalendarStyle.faint(palette)).frame(width: 44, alignment: .leading)
            value()
        }
        .frame(height: 42)
        .accessibilityElement(children: .combine)
    }
}

// MARK: Share a time

private struct ShareScreen: View {
    @ObservedObject var model: KeyboardModel
    let text: String?
    let palette: Theme.SystemKeyboard.Palette

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(text == nil ? "Nothing to share" : "Pip will insert").font(.system(size: 13)).foregroundStyle(CalendarStyle.faint(palette))
                Text(text ?? "No free hour between 9 AM and 6 PM in the next week.")
                    .font(.system(size: 17)).foregroundStyle(text == nil ? palette.secondaryLabel : palette.label)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("calendar.draft")
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CalendarStyle.card(palette), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .accessibilityElement(children: .combine)
            .padding(.top, 4)
            PipLine(text: text == nil ? "Try another week from the month." : "From your free time. You can edit it before you send.",
                    palette: palette, dark: model.isDark)
                .padding(.top, 8)
            Spacer(minLength: 0)
            GeometryReader { geo in
                HStack(spacing: 8) {
                    PanelButton(title: "Back", palette: palette, id: "calendar.shareBack", action: model.calendarBack)
                        .frame(width: (geo.size.width - 8) * 0.31)
                    PanelButton(title: "Insert", accent: true, palette: palette, id: "calendar.insert", enabled: text != nil, action: model.insertShare)
                }
            }
            .frame(height: 44)
        }
    }
}
