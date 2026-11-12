import SwiftUI

/// Home (B2-2): the sky with the wordmark, how much Pip explained today, the last drawing with Replay, the words looked up,
/// the plans caught in chats with Add, and the "Ask Pip" bar at the bottom.
struct HomeView: View {
    @EnvironmentObject var session: Session
    @ObservedObject private var calendar = CalendarModel.shared
    @ObservedObject private var keyboard = KeyboardSetup.shared
    // All read from the App Group, where the keyboard writes them; read again each time the app comes back.
    @State private var drawings: [Drawing] = []
    @State private var learned: [Learned] = []
    @State private var caught: [Caught] = []
    @State private var added: Set<String> = []
    @State private var replay: Drawing?

    /// Shown until the owner has looked words up: four common ones, as examples.
    static let starterWords = ["btw", "ngl", "iirc", "tbh"]

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                ZStack(alignment: .top) {
                    CloudSky(clouds: CloudSky.home).frame(height: 300).frame(maxWidth: .infinity)
                    VStack(alignment: .leading, spacing: 0) {
                        header
                        Text(headline).font(Theme.Font.title).tracking(Theme.Tracking.title).foregroundStyle(Theme.Color.text1)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, Theme.Metric.cardInset + 8).padding(.top, 18)
                            .accessibilityIdentifier("home.headline")
                        if let d = drawings.first { recentDrawing(d).padding(.top, 22) }
                        words.padding(.top, 24)
                        if !caught.isEmpty { fromChats.padding(.top, 26) }
                        if drawings.count > 1 { DrawingsSection(drawings: Array(drawings.dropFirst())).padding(.top, Theme.Space.s) }
                        setup.padding(.top, Theme.Metric.sectionGap)
                    }
                    .padding(.top, Theme.Space.xs)
                    .padding(.bottom, 120)
                }
            }
            .scrollIndicators(.hidden)
            .ignoresSafeArea(edges: .top)
            AskBar().padding(.horizontal, Theme.Metric.cardInset).padding(.bottom, Theme.Space.xs)
        }
        .background(Theme.Color.bg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .refreshable { reload() }
        .task(id: session.account) { reload() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in reload() }
        .sheet(item: $replay) { d in ReplaySheet(drawing: d) }
    }

    private func reload() {
        calendar.refresh()
        drawings = SharedStore.drawings
        learned = SharedStore.learned
        caught = SharedStore.caught.filter { !added.contains($0.id) }
    }

    private var learnedToday: [Learned] { learned.filter { Calendar.current.isDateInToday($0.date) } }

    private var headline: String {
        let n = learnedToday.count
        switch n {
        case 0: return "Ask Pip anything\nwhile you type"
        case 1: return "1 thing learned\ntoday"
        default: return "\(n) things learned\ntoday"
        }
    }

    private var header: some View {
        HStack(spacing: Theme.Space.xs) {
            Wordmark(size: 30)
            Spacer()
            NavigationLink { ShortcutsView() } label: { IconCircle(systemImage: "bolt") }
                .accessibilityLabel("Shortcuts")
                .accessibilityIdentifier("nav.shortcuts")
            NavigationLink { NotesView() } label: { IconCircle(systemImage: "note.text") }
                .accessibilityLabel("Notes")
                .accessibilityIdentifier("nav.notes")
        }
        .padding(.horizontal, Theme.Metric.cardInset + 8)
        .padding(.top, 62)
    }

    /// The last drawing, as a card with its title and Replay (B2: radius 22, ring shadow, ice Replay pill).
    private func recentDrawing(_ d: Drawing) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let url = SharedStore.drawingURL(d), let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image).resizable().scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 132)
                    .padding(.horizontal, 18).padding(.top, 12)
            }
            HStack {
                Text(d.title).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.Color.text1).lineLimit(1)
                Spacer()
                if d.sceneFile != nil {
                    Button("Replay") { replay = d }.buttonStyle(IcePill())
                        .accessibilityIdentifier("home.replay")
                }
            }
            .padding(.leading, 18).padding(.trailing, 14).padding(.bottom, 12).padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .ringCard()
        .padding(.horizontal, Theme.Metric.cardInset + 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.drawings")
    }

    /// The words looked up in the keyboard, or four examples until there are some.
    private var words: some View {
        let mine = learned.filter { $0.kind == .word }
        let list: [(String, String)] = mine.isEmpty
            ? Self.starterWords.compactMap { w in ExplainDictionary.shared.lookup(w).map { (w, $0.meaning) } }
            : Array(mine.prefix(6)).map { ($0.subject, $0.line) }
        return VStack(alignment: .leading, spacing: 12) {
            Text(mine.isEmpty ? "Words to try" : "Words").font(Theme.Font.section).foregroundStyle(Theme.Color.text1)
            FlowLayout(spacing: 8) {
                ForEach(list, id: \.0) { w, meaning in
                    (Text(w).fontWeight(.semibold).foregroundColor(Theme.Color.skyDeep) + Text("  \(meaning)").foregroundColor(Theme.Color.text1))
                        .font(.system(size: 15)).lineLimit(1)
                        .padding(.horizontal, 14).frame(height: 38)
                        .background(Theme.Color.ice, in: Capsule())
                }
            }
        }
        .padding(.horizontal, Theme.Metric.cardInset + 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.words")
    }

    /// Plans read in chats that are not on the calendar yet. Add puts them there from the app.
    private var fromChats: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("From your chats").font(Theme.Font.section).foregroundStyle(Theme.Color.text1).padding(.bottom, 6)
            ForEach(caught.prefix(4)) { c in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(c.title).font(.system(size: 16, weight: .medium)).foregroundStyle(Theme.Color.text1).lineLimit(1)
                        Text(c.place == .calendar ? "Calendar \u{00B7} \(Self.when(c.date, allDay: c.end == nil))" : "Reminder \u{00B7} \(Self.when(c.date, allDay: false))")
                            .font(.system(size: 13)).foregroundStyle(Theme.Color.text3)
                    }
                    Spacer()
                    if added.contains(c.id) {
                        Text("Added \u{2713}").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.Color.success)
                    } else {
                        Button("Add") { add(c) }.buttonStyle(SkyPill(height: 36, font: .system(size: 14, weight: .semibold), fullWidth: false))
                            .accessibilityIdentifier("home.add")
                    }
                }
                .frame(minHeight: 54)
            }
        }
        .padding(.horizontal, Theme.Metric.cardInset + 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.chats")
    }

    private func add(_ c: Caught) {
        let writer = EventKitWriter()
        let place: SmartChip.Place = c.place == .calendar ? .calendar : .reminders
        Task {
            if writer.access(place, hasFullAccess: true) != .ready { await calendar.connect() }
            guard writer.access(place, hasFullAccess: true) == .ready else { return }
            let ok = (try? (c.place == .calendar ? writer.addEvent(title: c.title, start: c.date, end: c.end) : writer.addReminder(title: c.title, due: c.date))) != nil
            guard ok else { return }
            withAnimation { _ = added.insert(c.id) }
            SharedStore.caught = SharedStore.caught.filter { $0.id != c.id }
        }
    }

    static func when(_ d: Date, allDay: Bool) -> String {
        let f = DateFormatter()
        f.dateFormat = allDay ? "EEE" : "EEE, h:mm a"
        return f.string(from: d)
    }

    /// Setup and account, below the day: only what still needs doing.
    private var setup: some View {
        VStack(alignment: .leading, spacing: Theme.Metric.cardGap) {
            if !keyboard.state.isOn || keyboard.state == .needsFullAccess || keyboard.state == .notFirst { keyboardCard }
            if calendar.neverAsked { calendarCard }
            if !session.appleLinked {
                SaveDetailsCard()
            } else if let notice = session.notice {
                Text(notice).font(Theme.Font.label).foregroundStyle(Theme.Color.success)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("home.saved")
            }
            #if DEBUG
            NavigationLink("Keyboard Lab (debug)") { KeyboardLabView() }
                .font(Theme.Font.label).foregroundStyle(Theme.Color.text2)
                .frame(minHeight: Theme.Metric.iconButton)
            #endif
            Button("Unpair this device", role: .destructive) { session.unpair() }
                .font(Theme.Font.label).frame(minHeight: Theme.Metric.iconButton)
        }
        .padding(.horizontal, Theme.Metric.cardInset + 8)
    }

    private var keyboardCard: some View {
        NavigationLink {
            ScrollView { EnableKeyboardSteps().padding(Theme.Metric.cardInset) }.background(Theme.Color.bg.ignoresSafeArea())
        } label: {
            Card {
                HStack(spacing: Theme.Space.s) {
                    Buddy(size: 34)
                    VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                        Text(keyboard.state.homeTitle).font(Theme.Font.cardTitle).foregroundStyle(Theme.Color.text1)
                        Text(keyboard.state == .needsFullAccess ? KeyboardState.finishSetupLine
                             : keyboard.state == .notFirst ? "Drag it to the top in Settings" : "Make it your default keyboard")
                            .font(Theme.Font.label).foregroundStyle(Theme.Color.text2)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(Theme.Color.text3)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("home.keyboard")
    }

    /// Optional, and never a blocking step. It goes away once the owner answers the system prompt.
    private var calendarCard: some View {
        Card {
            HStack(spacing: Theme.Space.s) {
                VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                    Text("Connect Calendar").font(Theme.Font.cardTitle).foregroundStyle(Theme.Color.text1)
                    Text("So Add puts plans from your chats on it").font(Theme.Font.label).foregroundStyle(Theme.Color.text2)
                }
                Spacer()
                Button("Connect") { Task { await calendar.connect() } }
                    .buttonStyle(IcePill())
                    .accessibilityIdentifier("home.calendar.connect")
            }
        }
    }
}

/// Lays chips out in rows, wrapping to the next row when one does not fit.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(proposal.width ?? .infinity, subviews)
        let h = rows.map { $0.map { subviews[$0].sizeThatFits(.unspecified).height }.max() ?? 0 }.reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? 0, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(bounds.width, subviews) {
            var x = bounds.minX
            let h = row.map { subviews[$0].sizeThatFits(.unspecified).height }.max() ?? 0
            for i in row {
                let s = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
                x += min(s.width, bounds.width) + spacing
            }
            y += h + spacing
        }
    }

    private func rows(_ width: CGFloat, _ subviews: Subviews) -> [[Int]] {
        var rows: [[Int]] = [[]]
        var x: CGFloat = 0
        for i in subviews.indices {
            let w = subviews[i].sizeThatFits(.unspecified).width
            if x > 0, x + w > width { rows.append([]); x = 0 }
            rows[rows.count - 1].append(i)
            x += w + spacing
        }
        return rows
    }
}
