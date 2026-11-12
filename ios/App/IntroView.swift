import SwiftUI
import UIKit

// The intro: one short scene per feature. Each scene runs the real keyboard on canned answers.
// It plays before sign-in, so nothing here can reach the server.

/// The intro's stand-in server. It answers from memory and makes no network call.
struct DemoAPI: KeyboardAPI {
    var fixed = ""

    func suggest(_ text: String, context: String?) async throws -> SuggestResponse { SuggestResponse(chips: [], intent: "none", timings: nil) }
    func fix(_ text: String) async throws -> WriteResponse { WriteResponse(text: fixed, changed: true) }
    func refine(_ text: String, tone: String) async throws -> WriteResponse { WriteResponse(text: text, changed: false) }
    func toneCheck(draft: String, client: String?) async throws -> ToneResponse { ToneResponse(tone: "ok", calm: nil) }
    func explain(_ text: String) async throws -> ExplainResponse { throw APIError.message("no explain in the intro") }
    func explainVisual(_ topic: String) async throws -> Data { throw APIError.message("no explain in the intro") }
    func shareDrawing(_ png: Data) async throws -> String { throw APIError.message("no sharing in the intro") }
}

/// The intro's device storage: kept in memory, gone when the intro ends.
final class DemoStore: KeyboardStore {
    let deviceToken: String? = "demo"
    var keyboardLastSeen: Date?
    var lastPasteboardChange = 0
    var appointments: [Appointment] = []
    var notes: [Note] = Note.demo
    let actionShortcuts = ActionShortcut.defaults
    func saveDrawing(_ png: Data, title: String) throws {}
}

/// The intro's calendar: it says yes and keeps nothing, so a scene never touches the real calendar.
final class DemoWriter: SmartWriter {
    func access(_ place: SmartChip.Place, hasFullAccess: Bool) -> SmartAccess { .ready }
    func addEvent(title: String, start: Date, end: Date?) throws -> String { UUID().uuidString }
    func addReminder(title: String, due: Date) throws -> String { UUID().uuidString }
    func removeEvent(_ id: String) throws {}
    func removeReminder(_ id: String) throws {}
}

/// The intro never looks at the real pasteboard.
final class DemoPasteboard: Pasteboard {
    let hasStrings = false
    let changeCount = 0
    let string: String? = nil
    func setPNG(_ png: Data) {}
}

/// One intro scene. To add a feature, add one value to `all`.
struct IntroScene: Identifiable {
    let id: String
    let title: String
    let line: String
    let skin: ChatSkin
    let contact: String
    let lines: [ChatLine]
    var fixed = ""
    /// "In WhatsApp": where the scene plays.
    var place: String { "In \(skin.app)" }
    /// What happens on screen, step by step.
    let script: @MainActor (IntroPlayer) async throws -> Void

    @MainActor static let all: [IntroScene] = [
        IntroScene(id: "write", title: "Fix and Rewrite", line: "Type fast. Fix shows the typos. Rewrite makes it polite or short.",
                   skin: .marketplace, contact: "Dana", lines: [.them("Is this still available?")],
                   fixed: "Yes it's available, can you pick it up today?") { p in
            try await p.type("yes it's availble, can u pick it up today")
            try await p.pause(300)
            try await p.tapBar(0.72)
            p.keyboard.fix()
            try await p.pause(800)
            try await p.tapBar(0.84)
            p.keyboard.toggleWrite()
        },
        IntroScene(id: "smart", title: "Calendar and reminders", line: "Type a plan in any chat. One tap adds it to your calendar.",
                   skin: .iMessage, contact: "Ana", lines: [.them("Dinner this week?")]) { p in
            try await p.type("dinner with Ana friday 7pm")
            p.keyboard.fieldEmpty = false
            p.keyboard.smart = SmartDetect.detect(p.stage.text, now: Date())
            try await p.pause(500)
            try await p.tapBar(0.4)
            if let chip = p.keyboard.smart.first { p.keyboard.tapSmart(chip) }
            try await p.pause(500)
            p.send()
        },
        IntroScene(id: "notes", title: "Notes", line: "Save a reply once. Drop it into any chat.",
                   skin: .whatsApp, contact: "Priya", lines: [.them("Where are you?")]) { p in
            try await p.pause(500)
            try await p.tapBar(0.94)
            p.keyboard.toggleNotes()
            try await p.pause(700)
            try await p.tapKeyboard(x: 0.5, y: Theme.SystemKeyboard.barHeight + 20)
            if let note = p.keyboard.notes.first { p.keyboard.insertNote(note) }
            try await p.pause(600)
            p.send()
        },
    ]
}

/// One scene's own keyboard and message field. Each scene starts clean.
@MainActor
final class IntroStage: ObservableObject, TextHost {
    @Published var text = ""
    let keyboard: KeyboardModel

    init(_ scene: IntroScene, dark: Bool) {
        let api = DemoAPI(fixed: scene.fixed)
        keyboard = KeyboardModel(deps: KeyboardDeps(api: { api }, store: DemoStore(), pasteboard: DemoPasteboard(), now: Date.init,
                                                    sleep: { try await Task.sleep(for: $0) }, writer: DemoWriter()))
        keyboard.host = self
        keyboard.suggestsWhileTyping = false
        keyboard.isDark = dark
        keyboard.keyboardAppeared()
    }

    var contextBeforeInput: String? { text }
    var hasFullAccess: Bool { true }
    var needsGlobeKey: Bool { false }
    var returnKeyType: UIReturnKeyType { .default }
    var autocapitalization: UITextAutocapitalizationType { .sentences }
    var enablesReturnKeyAutomatically: Bool { false }
    func playClick() {}
    func insert(_ s: String) { text += s }
    func deleteBackward() { if !text.isEmpty { text.removeLast() } }
    func nextKeyboard() {}
}

/// Plays the scenes in order: about 3 s each, then the next. A tap skips ahead.
@MainActor
final class IntroPlayer: ObservableObject {
    @Published private(set) var index = 0
    @Published private(set) var stage: IntroStage
    /// What the owner "sent" in this scene.
    @Published private(set) var sent: [String] = []
    /// Where the finger is, in the keyboard: x from 0 to 1, y in points from its top.
    @Published private(set) var touch: CGPoint?
    /// The scene has shown everything.
    @Published private(set) var settled = false

    static let typeDelay = 26
    static let endHold = 900
    /// DEBUG "-introHold": a scene stays until a tap, so a test can take its picture.
    private let holds = ProcessInfo.processInfo.arguments.contains("-introHold")
    private var dark = false
    private var task: Task<Void, Never>?
    private var finish: () -> Void = {}

    init() { stage = IntroStage(IntroScene.all[0], dark: false) }

    var scene: IntroScene { IntroScene.all[index] }
    var keyboard: KeyboardModel { stage.keyboard }

    func start(dark: Bool, finish: @escaping () -> Void) {
        self.dark = dark
        self.finish = finish
        play(0)
    }

    /// A tap: on to the next scene now. After the last one, the intro ends.
    func next() {
        if index + 1 < IntroScene.all.count { play(index + 1) } else { stop(); finish() }
    }

    func stop() { task?.cancel() }

    private func play(_ i: Int) {
        task?.cancel()
        stage.keyboard.keyboardDisappeared()
        index = i
        stage = IntroStage(IntroScene.all[i], dark: dark)
        sent = []
        touch = nil
        settled = false
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.scene.script(self)
                try await self.pause(Self.endHold)
                self.settled = true
                if !self.holds { self.next() }
            } catch {}
        }
    }

    // MARK: script steps

    func pause(_ ms: Int) async throws { try await Task.sleep(for: .milliseconds(ms)) }

    /// Types into the chat.
    func type(_ text: String) async throws {
        for ch in text {
            stage.text.append(ch)
            keyboard.textChanged()
            try await pause(Self.typeDelay)
        }
    }

    /// A finger on the bar at `x` (0 to 1).
    func tapBar(_ x: CGFloat) async throws { try await tapKeyboard(x: x, y: 24) }

    func tapKeyboard(x: CGFloat, y: CGFloat) async throws {
        withAnimation(Theme.Motion.press) { touch = CGPoint(x: x, y: y) }
        try await pause(280)
        withAnimation(Theme.Motion.crossfade) { touch = nil }
    }

    /// The message leaves the field and lands in the chat.
    func send() {
        guard !stage.text.isEmpty else { return }
        withAnimation(Theme.Motion.chipFlip) { sent.append(stage.text) }
        stage.text = ""
        keyboard.textChanged()
    }
}

struct IntroView: View {
    let done: () -> Void
    @StateObject private var player = IntroPlayer()
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    typealias K = Theme.SystemKeyboard

    var body: some View {
        let scene = player.scene
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                HStack(spacing: Theme.Space.s) {
                    HStack(spacing: Theme.Space.xxs) {
                        ForEach(IntroScene.all.indices, id: \.self) { i in
                            Capsule().fill(i == player.index ? Theme.Color.text1 : i < player.index ? Theme.Color.text2 : Theme.Color.tick).frame(height: 4)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Feature \(player.index + 1) of \(IntroScene.all.count)")
                    Button("Skip") { player.stop(); done() }
                        .font(Theme.Font.body).foregroundStyle(Theme.Color.text2)
                        .frame(minWidth: Theme.Metric.iconButton, minHeight: Theme.Metric.iconButton)
                        .accessibilityIdentifier("onboarding.skip")
                }
                VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                    // The other app is named in words only.
                    Text(scene.place).font(Theme.Font.label).foregroundStyle(Theme.Color.text2)
                        .accessibilityIdentifier("intro.place")
                    Text(scene.title).font(Theme.Font.title).foregroundStyle(Theme.Color.text1)
                        .accessibilityIdentifier(player.settled ? "intro.done.\(scene.id)" : "intro.playing.\(scene.id)")
                    Text(scene.line).font(Theme.Font.body).foregroundStyle(Theme.Color.text2)
                        .lineLimit(2, reservesSpace: true).minimumScaleFactor(0.85)
                }
                .padding(.horizontal, Theme.Space.xs)
                .frame(maxWidth: .infinity, alignment: .leading)
                .id(scene.id)
                .transition(.opacity)
                .allowsHitTesting(false)
                StageView(player: player, stage: player.stage, scene: scene)
                    .id(scene.id)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
            .padding(.horizontal, Theme.Metric.cardInset)
            .padding(.bottom, Theme.Space.xs)
            KeyboardView(model: player.keyboard)
                .overlay(alignment: .topLeading) {
                    GeometryReader { g in
                        if let t = player.touch {
                            Circle().fill(Theme.Color.text1.opacity(0.22)).overlay(Circle().strokeBorder(Theme.Color.text1.opacity(0.35), lineWidth: 1))
                                .frame(width: 40, height: 40)
                                .position(x: t.x * g.size.width, y: t.y)
                                .transition(.scale(scale: 1.5).combined(with: .opacity))
                        }
                    }
                }
                .background((colorScheme == .dark ? K.dark : K.light).bed.ignoresSafeArea(edges: .bottom))
                .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Color.bg.ignoresSafeArea())
        // Skip is the only control. Everywhere else, a tap goes on to the next scene.
        .contentShape(Rectangle())
        .onTapGesture { player.next() }
        .animation(reduceMotion ? nil : Theme.Motion.crossfade, value: player.index)
        .onAppear { player.start(dark: colorScheme == .dark, finish: done) }
        .onDisappear { player.stop() }
        .onChange(of: colorScheme) { _, scheme in player.keyboard.isDark = scheme == .dark }
    }
}

/// The scene's surface: a chat in another app.
private struct StageView: View {
    @ObservedObject var player: IntroPlayer
    @ObservedObject var stage: IntroStage
    let scene: IntroScene

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Metric.radius, style: .continuous)
        ChatView(skin: scene.skin, contact: scene.contact, lines: scene.lines, sent: player.sent, draft: stage.text)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Theme.Color.edge, lineWidth: 1))
    }
}
