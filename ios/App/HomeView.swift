import SwiftUI

struct HomeView: View {
    @EnvironmentObject var session: Session
    @ObservedObject private var calendar = CalendarModel.shared
    @ObservedObject private var keyboard = KeyboardSetup.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Metric.cardGap) {
                header
                keyboardCard
                if calendar.neverAsked { calendarCard }
                if !calendar.today.isEmpty { todaySection }
                if !session.appleLinked {
                    SaveDetailsCard().padding(.horizontal, Theme.Metric.cardInset)
                } else if let notice = session.notice {
                    Text(notice).font(Theme.Font.label).foregroundStyle(Theme.Color.paid)
                        .padding(.horizontal, Theme.Metric.margin).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("home.saved")
                }
                #if DEBUG
                NavigationLink("Keyboard Lab (debug)") { KeyboardLabView() }
                    .font(Theme.Font.label).foregroundStyle(Theme.Color.text2)
                    .frame(minHeight: Theme.Metric.iconButton).padding(.horizontal, Theme.Metric.margin)
                    .padding(.top, Theme.Metric.sectionGap - Theme.Metric.cardGap)
                #endif
                Button("Unpair this device", role: .destructive) { session.unpair() }
                    .font(Theme.Font.label).frame(minHeight: Theme.Metric.iconButton).padding(.horizontal, Theme.Metric.margin)
            }
            .padding(.top, Theme.Space.xs)
            .padding(.bottom, Theme.Space.l)
        }
        .scrollIndicators(.hidden)
        .background(Theme.Color.bg.ignoresSafeArea())
        // No navigation bar here, so cover the status bar: scrolled cards never run under the clock.
        .overlay(alignment: .top) { Theme.Color.bg.frame(height: 0).ignoresSafeArea(edges: .top) }
        .toolbar(.hidden, for: .navigationBar)
        .refreshable { calendar.refresh() }
        .task(id: session.account) { calendar.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in calendar.refresh() }
    }

    private var header: some View {
        HStack(spacing: Theme.Space.xs) {
            MarkView(size: 36)
            Text(AppConfig.displayName).font(Theme.Font.appName).tracking(Theme.Tracking.appName).foregroundStyle(Theme.Color.text1)
            Spacer()
            NavigationLink { ShortcutsView() } label: { IconCircle(systemImage: "bolt") }
                .accessibilityLabel("Shortcuts")
                .accessibilityIdentifier("nav.shortcuts")
            NavigationLink { NotesView() } label: { IconCircle(systemImage: "note.text") }
                .accessibilityLabel("Notes")
                .accessibilityIdentifier("nav.notes")
        }
        .padding(.horizontal, Theme.Metric.cardInset)
        .padding(.bottom, Theme.Space.xs)
    }

    /// Today's events from the phone calendar.
    private var todaySection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionHeader(title: "Today", count: calendar.today.count)
            Card(padding: 0) {
                TimelineView(.everyMinute) { now in
                    VStack(spacing: 0) {
                        ForEach(calendar.today) { a in
                            appointmentRow(a, ended: a.end <= now.date)
                        }
                    }
                }
                .padding(.vertical, Theme.Space.xs)
            }
            .padding(.horizontal, Theme.Metric.cardInset)
        }
        .padding(.top, Theme.Metric.sectionGap - Theme.Metric.cardGap)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.today")
    }

    private func appointmentRow(_ a: Appointment, ended: Bool) -> some View {
        HStack(spacing: Theme.Space.s) {
            Text(a.time).font(Theme.Font.body).monospacedDigit().foregroundStyle(ended ? Theme.Color.text3 : Theme.Color.text1)
                .frame(width: Theme.Space.xxl, alignment: .leading)
            Text(a.title).font(Theme.Font.body).foregroundStyle(ended ? Theme.Color.text3 : Theme.Color.text1).lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, Theme.Metric.cardPadding)
        .frame(minHeight: Theme.Metric.rowHeight)
    }

    private var keyboardCard: some View {
        NavigationLink {
            ScrollView { EnableKeyboardSteps().padding(Theme.Metric.cardInset) }.background(Theme.Color.bg.ignoresSafeArea())
        } label: {
            Card {
                HStack(spacing: Theme.Space.s) {
                    IconCircle(systemImage: "keyboard")
                    VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                        Text(keyboard.state.homeTitle)
                            .font(Theme.Font.cardTitle).foregroundStyle(Theme.Color.text1)
                        if keyboard.state == .needsFullAccess {
                            Text(KeyboardState.finishSetupLine).font(Theme.Font.label).foregroundStyle(Theme.Color.text2)
                        } else if keyboard.state == .notFirst {
                            Text("Drag it to the top in Settings").font(Theme.Font.label).foregroundStyle(Theme.Color.text2)
                        } else if !keyboard.state.isOn {
                            Text("Make it your default keyboard").font(Theme.Font.label).foregroundStyle(Theme.Color.text2)
                        } else {
                            Text("Fix, Rewrite and smart chips in every chat").font(Theme.Font.label).foregroundStyle(Theme.Color.text2)
                        }
                    }
                    Spacer()
                    IconCircle(systemImage: "chevron.right")
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Theme.Metric.cardInset)
        .accessibilityIdentifier("home.keyboard")
    }

    /// Optional, and never a blocking step. It goes away once the owner answers the system prompt.
    private var calendarCard: some View {
        Card {
            HStack(spacing: Theme.Space.s) {
                IconCircle(systemImage: "calendar")
                VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                    Text("Connect Calendar").font(Theme.Font.cardTitle).foregroundStyle(Theme.Color.text1)
                    Text("Today's events, and the ones you type").font(Theme.Font.label).foregroundStyle(Theme.Color.text2)
                }
                Spacer()
                AskChip(title: "Connect", detail: nil) { Task { await calendar.connect() } }
                    .accessibilityIdentifier("home.calendar.connect")
            }
        }
        .padding(.horizontal, Theme.Metric.cardInset)
    }
}

struct AskChip: View {
    let title: String
    let detail: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(Theme.Font.urbanist(15, 600)).foregroundStyle(Theme.Color.text1)
                if let detail { Text(detail).font(Theme.Font.urbanist(11, 500)).foregroundStyle(Theme.Color.text3) }
            }
            .lineLimit(1)
            .padding(.horizontal, Theme.Space.m)
            .frame(height: Theme.Metric.chipHeight + (detail == nil ? 0 : Theme.Space.xs))
            .background(Theme.Color.button, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.Color.chipEdge, lineWidth: 1))
        }
        .buttonStyle(PressScale())
    }
}
