import SwiftUI

/// One short flow: the intro, turn on the keyboard, make it the default, allow Calendar & Reminders, sign in (Apple, email,
/// or skip for now), Home.
/// After the intro, each step fits one screen and has one main button.
struct OnboardingView: View {
    enum Step: Int, CaseIterable { case intro, keyboard, makeDefault, calendar, start }

    @EnvironmentObject var session: Session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var setup = KeyboardSetup.shared
    @Environment(\.colorScheme) private var colorScheme
    /// iOS ends the app when the owner turns on the keyboard in Settings. The next launch goes on after the intro, not back into it.
    private static let introSeenKey = "intro_seen"
    @State private var step: Step = UserDefaults.standard.bool(forKey: introSeenKey) ? keyboardStep : .intro
    @State private var checked = false
    @State private var busy = false
    #if DEBUG
    @State private var showDevPairing = false
    #endif

    private var title: String {
        switch step {
        case .intro: ""
        case .keyboard: "Turn on the keyboard"
        case .makeDefault: "Make it your default"
        case .calendar: "Allow Calendar & Reminders"
        case .start: AppConfig.tagline
        }
    }
    private var line: String {
        switch step {
        case .intro: ""
        case .keyboard: "Three taps in Settings. Then come back."
        case .makeDefault: setup.state == .notFirst ? KeyboardState.reorderSteps : "So it opens first in every chat."
        case .calendar: "The keyboard adds the events and reminders you type. They stay on this phone."
        case .start: AppConfig.taglineLine
        }
    }
    private var stepMotion: Animation { reduceMotion ? Theme.Motion.crossfade : Theme.Motion.onboardingStep }
    private var slide: AnyTransition {
        reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                              removal: .move(edge: .leading).combined(with: .opacity))
    }

    var body: some View {
        Group {
            if step == .intro {
                OnboardingHero { Task { await advance(from: .intro) } }.transition(.opacity)
            } else {
                steps.transition(.opacity)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { if session.signInNext { step = .start } }
        #if DEBUG
        .sheet(isPresented: $showDevPairing) {
            DevPairingSheet { showDevPairing = false; Task { await complete(.start) } }
        }
        #endif
        // RootView checks the keyboard each time the app comes back from Settings.
        // Added with Full Access and first in the list: nothing is left to set, so the default step ticks and moves on.
        .onChange(of: setup.state) { _, state in
            if step == .keyboard, state != .notAdded, !checked { Task { await complete(.keyboard) } }
            if step == .makeDefault, state == .ready, !checked { Task { await complete(.makeDefault) } }
        }
    }

    private var steps: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                StepDots(count: Step.allCases.count, current: step.rawValue)
                    .padding(.top, Theme.Space.s)
                Spacer(minLength: 0).frame(maxHeight: step == .start ? .infinity : Theme.Space.xl)
                mark
                VStack(spacing: Theme.Space.xs) {
                    Text(title).font(Theme.Font.title).tracking(Theme.Tracking.title).foregroundStyle(Theme.Color.text1)
                        .multilineTextAlignment(.center)
                    Text(line).font(Theme.Font.body).foregroundStyle(Theme.Color.text2)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    if step == .keyboard { keyboardSteps.padding(.top, Theme.Space.m) }
                    if step == .makeDefault { Card { KeyboardDefaultGuide() }.padding(.top, Theme.Space.m) }
                }
                .padding(.top, Theme.Space.l)
                .id(step)
                .transition(slide)
                Spacer(minLength: Theme.Space.l).frame(maxHeight: .infinity)
                if let error = session.error {
                    Text(error).font(Theme.Font.label).foregroundStyle(Theme.Color.warning)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, Theme.Space.s)
                        .accessibilityIdentifier("onboarding.error")
                }
                actions
                    .id(step)
                    .transition(.opacity)
                    .disabled(busy || checked)
            }
            .padding(.horizontal, Theme.Metric.cardInset)
            .padding(.bottom, Theme.Space.m)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(alignment: .top) {
            // B2: the sky stays on onboarding, fading to white behind the steps.
            ZStack(alignment: .top) {
                Theme.Color.bg
                SkyGradient().frame(height: 300)
            }
            .ignoresSafeArea()
        }
    }

    /// The mark is one view for the whole flow. It is large on the first screen, then moves up and shrinks.
    /// A finished step stamps a green check on it.
    private var mark: some View {
        let size: CGFloat = step == .start ? 104 : 64
        return ZStack {
            MarkView(size: size)
            if checked {
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.4, weight: .semibold))
                    .foregroundStyle(Theme.Color.successInk)
                    .frame(width: size, height: size)
                    .background(Theme.Color.successChip, in: Circle())
                    .overlay(Circle().strokeBorder(Theme.Color.successEdge, lineWidth: 1))
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.4).combined(with: .opacity))
            }
        }
        .contentShape(Circle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AppConfig.displayName)
        .accessibilityIdentifier("onboarding.mark")
        #if DEBUG
        // Hidden developer path, Debug builds only: hold the mark on the last screen to pair with a device token.
        .onLongPressGesture(minimumDuration: 0.8) { if step == .start { session.error = nil; showDevPairing = true } }
        #endif
    }

    private var keyboardSteps: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                ForEach(Array(["Tap Keyboards.", "Turn on \(AppConfig.keyboardName).", "Turn on Allow Full Access."].enumerated()), id: \.offset) { i, text in
                    HStack(spacing: Theme.Space.s) {
                        Text("\(i + 1)").font(Theme.Font.count).foregroundStyle(Theme.Color.text1)
                            .frame(width: Theme.Space.xl, height: Theme.Space.xl).background(Theme.Color.button, in: Circle())
                        Text(text).font(Theme.Font.body).foregroundStyle(Theme.Color.text1)
                    }
                }
            }
        }
    }

    @ViewBuilder private var actions: some View {
        VStack(spacing: Theme.Space.xs) {
            switch step {
            case .start:
                SignInChoices(busy: busy, skip: { Task { await getStarted() } }, signedIn: { Task { await complete(.start) } })
            case .keyboard:
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                .buttonStyle(PrimaryButton())
                quietButton("Not now") { Task { await advance(from: .keyboard, skipped: true) } }
                    .accessibilityIdentifier("onboarding.later")
            case .makeDefault:
                if let open = setup.state.settingsButton {
                    Button(open) {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    .buttonStyle(PrimaryButton())
                    .accessibilityIdentifier("onboarding.default.settings")
                } else {
                    Button("Next") { Task { await complete(.makeDefault) } }
                        .buttonStyle(PrimaryButton())
                        .accessibilityIdentifier("onboarding.default.next")
                }
                // Not first is a hint, never a blocker: the keyboard works, so Next stays one tap away.
                if setup.state == .notFirst {
                    quietButton("Next") { Task { await complete(.makeDefault) } }
                        .accessibilityIdentifier("onboarding.default.next")
                } else {
                    quietButton("Not now") { Task { await advance(from: .makeDefault) } }
                        .accessibilityIdentifier("onboarding.default.later")
                }
            case .calendar:
                Button("Allow Calendar & Reminders") { Task { await CalendarModel.shared.connect(); await advance(from: .calendar) } }
                    .buttonStyle(PrimaryButton())
                    .accessibilityIdentifier("onboarding.calendar")
                quietButton("Not now") { Task { await advance(from: .calendar) } }
                    .accessibilityIdentifier("onboarding.calendar.later")
            case .intro:
                EmptyView()
            }
        }
    }

    private func quietButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(Theme.Font.body).foregroundStyle(Theme.Color.text2)
            .frame(maxWidth: .infinity, minHeight: Theme.Metric.secondaryButton)
    }

    /// Makes the device account. A failure leaves the button in place with one plain line above it.
    private func getStarted() async {
        session.error = nil
        busy = true
        let ok = await session.getStarted()
        busy = false
        if ok { await complete(.start) }
    }

    /// The step is done: stamp the check, hold it a moment, then move on.
    private func complete(_ done: Step) async {
        // Several changes can report the same success. Only the first one counts, or the intro would jump scenes.
        guard !checked else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        withAnimation(reduceMotion ? Theme.Motion.crossfade : Theme.Motion.stamp) { checked = true }
        try? await Task.sleep(for: Theme.Motion.onboardingCheckHold)
        await advance(from: done)
    }

    private func advance(from done: Step, skipped: Bool = false) async {
        withAnimation(stepMotion) {
            checked = false
            session.error = nil
            if done == .intro { UserDefaults.standard.set(true, forKey: Self.introSeenKey) }
            if let next = skipped && done == .keyboard ? Self.afterKeyboard : next(after: done) { step = next } else { session.finishOnboarding() }
        }
    }

    /// Skips the add step when the keyboard is already added. "Not now" on the add step also skips the default step.
    private func next(after done: Step) -> Step? {
        switch done {
        case .intro: Self.keyboardStep
        case .keyboard: KeyboardSetup.shared.state == .ready ? Self.afterKeyboard : .makeDefault
        case .makeDefault: Self.afterKeyboard
        case .calendar: .start
        case .start: nil
        }
    }

    /// The calendar step shows only while Calendar or Reminders has never been asked.
    @MainActor static var afterKeyboard: Step { CalendarModel.shared.neverAsked ? .calendar : .start }

    /// Skips what is already done: the add step once the keyboard is added, and both keyboard steps once it is ready
    /// (added, Full Access seen, first in the list).
    @MainActor static var keyboardStep: Step {
        switch KeyboardSetup.shared.state {
        case .notAdded: .keyboard
        case .ready: afterKeyboard
        case .needsFullAccess, .notFirst: .makeDefault
        }
    }
}

/// One dot per step. The current one is a longer pill.
struct StepDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(i <= current ? Theme.Color.sky : Color.white.opacity(0.8))
                    .frame(width: i == current ? Theme.Space.l : 6, height: 6)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(current + 1) of \(count)")
        .accessibilityIdentifier("onboarding.step.\(current + 1)")
    }
}

#if DEBUG
/// Developer path, opened by holding the mark. It pairs with a device token from `npm run device`. Debug builds only.
struct DevPairingSheet: View {
    @EnvironmentObject var session: Session
    @State private var server = SharedStore.serverURL
    @State private var token = ""
    @State private var busy = false
    let onPaired: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("Developer pairing").font(Theme.Font.cardTitle).foregroundStyle(Theme.Color.text1)
            TextField("", text: $server, prompt: Text("Server URL").foregroundStyle(Theme.Color.text3))
                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                .modifier(FieldStyle())
            if let demo = AppConfig.demoServerURL {
                HStack(spacing: Theme.Space.xs) {
                    ServerOption(title: "This Mac", selected: server == "http://localhost:8787") { server = "http://localhost:8787" }
                    ServerOption(title: "Demo server", selected: server == demo) { server = demo }
                        .accessibilityIdentifier("server.demo")
                }
            }
            SecureField("", text: $token, prompt: Text("Device token (pkd_…)").foregroundStyle(Theme.Color.text3))
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .textContentType(.oneTimeCode)
                .modifier(FieldStyle())
                .accessibilityIdentifier("token")
            if let error = session.error {
                Text(error).font(Theme.Font.label).foregroundStyle(Theme.Color.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("pair.error")
            }
            Button(busy ? "Pairing…" : "Pair") {
                busy = true
                Task {
                    let ok = await session.pair(token: token, server: server)
                    busy = false
                    if ok { onPaired() }
                }
            }
            .buttonStyle(PrimaryButton())
            .disabled(token.isEmpty || busy)
            Spacer(minLength: 0)
        }
        .padding(Theme.Metric.cardPadding)
        .padding(.top, Theme.Space.xs)
        .background(Theme.Color.bg.ignoresSafeArea())
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}
#endif

struct EnableKeyboardSteps: View {
    @ObservedObject private var setup = KeyboardSetup.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metric.cardGap) {
            // No step number here: the guide numbers its own steps.
            Card {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Text(setup.state == .ready ? "Make it your default" : setup.state.homeTitle)
                        .font(Theme.Font.cardTitle).foregroundStyle(Theme.Color.text1)
                    if setup.state == .needsFullAccess {
                        Text(KeyboardState.finishSetupLine).font(Theme.Font.body).foregroundStyle(Theme.Color.text2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    KeyboardDefaultGuide()
                    OpenSettingsButton()
                }
            }
            StepCard(number: 3, title: "Optional: skip the paste prompt") {
                Text("To use a copied message, iOS asks each time. To stop the prompt, open Settings › \(AppConfig.displayName) › Paste from Other Apps and pick Allow.")
                    .font(Theme.Font.body).foregroundStyle(Theme.Color.text2).fixedSize(horizontal: false, vertical: true)
                OpenSettingsButton()
            }
            .accessibilityIdentifier("step.paste")
        }
    }
}

struct OpenSettingsButton: View {
    var body: some View {
        Button("Open Settings") {
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        }
        .buttonStyle(PrimaryButton())
    }
}

#if DEBUG
struct ServerOption: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.Font.label)
                .foregroundStyle(selected ? Theme.Color.bg : Theme.Color.text2)
                .padding(.horizontal, Theme.Space.m)
                .frame(height: Theme.Metric.iconButton)
                .background(selected ? Theme.Color.text1 : Theme.Color.button, in: Capsule())
        }
        .buttonStyle(PressScale())
    }
}
#endif

struct StepCard<Content: View>: View {
    let number: Int
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack(spacing: Theme.Space.s) {
                    Text("\(number)").font(Theme.Font.count).foregroundStyle(Theme.Color.text1)
                        .frame(width: Theme.Space.xl, height: Theme.Space.xl).background(Theme.Color.button, in: Circle())
                    Text(title).font(Theme.Font.cardTitle).foregroundStyle(Theme.Color.text1)
                }
                content
            }
        }
    }
}

struct FieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(Theme.Font.body)
            .foregroundStyle(Theme.Color.text1)
            .padding(.horizontal, Theme.Space.m)
            .frame(height: Theme.Metric.secondaryButton)
            .background(Theme.Color.button, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.Color.edge, lineWidth: 1))
    }
}

/// The one main action on a screen: the sky pill.
struct PrimaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SkyPill().makeBody(configuration: configuration)
    }
}
