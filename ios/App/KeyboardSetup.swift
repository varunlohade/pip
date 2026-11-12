import SwiftUI

/// Where the owner is with the keyboard. iOS has no API to set the default keyboard,
/// so the app shows the steps and checks each one it can see.
enum KeyboardState: Equatable {
    /// `notFirst`: on, with Full Access, but another keyboard is above it in Settings. A hint, never a blocker.
    case notAdded, needsFullAccess, notFirst, ready

    /// The keyboard has appeared with Full Access, so the app is fully usable.
    var isOn: Bool { self == .notFirst || self == .ready }

    var homeTitle: String {
        switch self {
        case .notAdded: "Add the \(AppConfig.displayName) keyboard"
        // Full Access may be on already: iOS only tells the app once the keyboard has opened with it.
        case .needsFullAccess: "Finish keyboard setup"
        case .notFirst: "Make \(AppConfig.displayName) your first keyboard"
        case .ready: "Keyboard is on"
        }
    }

    /// The onboarding button that opens Settings, or nil when nothing is left to set.
    var settingsButton: String? {
        switch self {
        // The app's own Settings page holds its Keyboards switch and Allow Full Access.
        case .notAdded, .needsFullAccess: "Open \(AppConfig.displayName) settings"
        // iOS allows no deep link to Settings › General › Keyboard. The app's own page is the closest one allowed,
        // so the copy names the path to the list where the owner drags the keyboard to the top.
        case .notFirst: "Open Settings"
        case .ready: nil
        }
    }

    static let finishSetupLine = "Turn on Allow Full Access, then open \(AppConfig.displayName) once in any chat"

    static let reorderSteps = "Settings › General › Keyboard › Keyboards › Edit, then drag \(AppConfig.displayName) to the top."
}

/// The one keyboard check for onboarding and Home.
@MainActor
final class KeyboardSetup: ObservableObject {
    static let shared = KeyboardSetup()

    @Published private(set) var state: KeyboardState = .notAdded
    private let read: () -> (enabled: [String], lastSeen: Date?)

    /// `enabled`: the AppleKeyboards preference, the keyboards on in Settings, in their Settings order.
    /// `lastSeen`: the heartbeat the keyboard writes each time it appears. It only lands with Full Access.
    init(read: @escaping () -> (enabled: [String], lastSeen: Date?) = {
        (UserDefaults.standard.stringArray(forKey: "AppleKeyboards") ?? [], SharedStore.keyboardLastSeen)
    }) {
        self.read = read
        refresh()
    }

    func refresh() {
        let r = read()
        let s = Self.state(enabled: r.enabled, lastSeen: r.lastSeen)
        if s != state { state = s }
    }

    nonisolated static let keyboardID = (Bundle.main.bundleIdentifier ?? "com.orseliyas.pip") + ".keyboard"

    nonisolated static func state(enabled: [String], lastSeen: Date?, keyboardID: String = keyboardID) -> KeyboardState {
        // An empty list means iOS did not share it. Then only the heartbeat can say the keyboard is there.
        let added = enabled.isEmpty ? lastSeen != nil : enabled.contains(keyboardID)
        guard added else { return .notAdded }
        guard lastSeen != nil else { return .needsFullAccess }
        // An empty list gives no order, so it counts as first.
        return enabled.isEmpty || enabled.first == keyboardID ? .ready : .notFirst
    }
}

/// "Make it your default": the Settings steps, then a field to try the keyboard in.
/// The check shows when the keyboard's heartbeat arrives.
struct KeyboardDefaultGuide: View {
    @ObservedObject var setup = KeyboardSetup.shared
    @State private var tryText = ""

    private var lines: [String] {
        var l = ["Open Settings › General › Keyboard › Keyboards."]
        if setup.state == .notAdded { l.append("Tap Add New Keyboard. Pick \(AppConfig.displayName).") }
        l.append("Tap Edit. Drag \(AppConfig.displayName) to the top.")
        l.append("Tap \(AppConfig.displayName). Turn on Allow Full Access.")
        return l
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            ForEach(Array(lines.enumerated()), id: \.offset) { i, text in
                HStack(spacing: Theme.Space.s) {
                    Text("\(i + 1)").font(Theme.Font.count).foregroundStyle(Theme.Color.text1)
                        .frame(width: Theme.Space.xl, height: Theme.Space.xl).background(Theme.Color.button, in: Circle())
                    Text(text).font(Theme.Font.body).foregroundStyle(Theme.Color.text1)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Group {
                if setup.state.isOn {
                    Label("\(AppConfig.displayName) is on", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Theme.Color.paidInk)
                        .accessibilityIdentifier("keyboard.on")
                    if setup.state == .notFirst {
                        Label(KeyboardState.notFirst.homeTitle, systemImage: "arrow.up")
                            .foregroundStyle(Theme.Color.text2)
                            .accessibilityIdentifier("keyboard.notFirst")
                    }
                } else {
                    Label("Try it: hold the globe key, pick \(AppConfig.displayName).", systemImage: "globe")
                        .foregroundStyle(Theme.Color.text2)
                }
            }
            .font(Theme.Font.label)
            .padding(.top, Theme.Space.xs)
            TextField("", text: $tryText, prompt: Text("Type here").foregroundStyle(Theme.Color.text3))
                .modifier(FieldStyle())
                .accessibilityIdentifier("keyboard.tryit")
        }
        // The keyboard can appear while the app stays open, so look for its heartbeat each second until it lands.
        .task(id: setup.state) {
            while !setup.state.isOn, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                setup.refresh()
            }
        }
    }
}
