import Foundation
import UIKit
import UniformTypeIdentifiers

/// The server calls the keyboard makes. APIClient is the real one; tests pass a fake.
protocol KeyboardAPI {
    func suggest(_ text: String, context: String?) async throws -> SuggestResponse
    func fix(_ text: String) async throws -> WriteResponse
    func refine(_ text: String, tone: String) async throws -> WriteResponse
    func toneCheck(draft: String, client: String?) async throws -> ToneResponse
    func explain(_ text: String) async throws -> ExplainResponse
    func explainVisual(_ topic: String) async throws -> Data
    func shareDrawing(_ png: Data, preview: Data?, title: String) async throws -> String
}

extension APIClient: KeyboardAPI {}

/// What the keyboard reads and writes on the device. SharedKeyboardStore is the real one.
protocol KeyboardStore: AnyObject {
    var deviceToken: String? { get }
    var keyboardLastSeen: Date? { get set }
    var lastPasteboardChange: Int { get set }
    var appointments: [Appointment] { get }
    var notes: [Note] { get set }
    var actionShortcuts: [ActionShortcut] { get }
    /// An exported visual explanation, kept in the App Group so the app's Home shows it and can replay it.
    func saveDrawing(_ png: Data, title: String, scene: Data?) throws
    /// Home's "things learned today": a word, answer or chart the owner opened.
    func recordLearned(_ l: Learned)
    /// Home's "From your chats": plans shown as chips. `added` removes one the owner already added.
    func recordCaught(_ c: Caught)
    func removeCaught(id: String)
}

final class SharedKeyboardStore: KeyboardStore {
    var deviceToken: String? { SharedStore.deviceToken }
    var keyboardLastSeen: Date? {
        get { SharedStore.keyboardLastSeen }
        set { SharedStore.keyboardLastSeen = newValue }
    }
    var lastPasteboardChange: Int {
        get { SharedStore.lastPasteboardChange }
        set { SharedStore.lastPasteboardChange = newValue }
    }
    var appointments: [Appointment] { SharedStore.appointments }
    var notes: [Note] {
        get { SharedStore.notes }
        set { SharedStore.notes = newValue }
    }
    var actionShortcuts: [ActionShortcut] { SharedStore.actionShortcuts }
    func saveDrawing(_ png: Data, title: String, scene: Data?) throws { try SharedStore.saveDrawing(png, title: title, scene: scene) }
    func recordLearned(_ l: Learned) { SharedStore.learned = [l] + SharedStore.learned.filter { $0.id != l.id } }
    func recordCaught(_ c: Caught) {
        let all = SharedStore.caught
        if !all.contains(where: { $0.id == c.id }) { SharedStore.caught = [c] + all }
    }
    func removeCaught(id: String) { SharedStore.caught = SharedStore.caught.filter { $0.id != id } }
}

/// The parts of UIPasteboard the keyboard uses. Only reading `string` can show the paste prompt.
protocol Pasteboard: AnyObject {
    var hasStrings: Bool { get }
    var changeCount: Int { get }
    var string: String? { get }
    /// Puts an image on the pasteboard, so it pastes into a chat. Needs Full Access in the keyboard.
    func setPNG(_ png: Data)
}

extension UIPasteboard: Pasteboard {
    func setPNG(_ png: Data) { setData(png, forPasteboardType: UTType.png.identifier) }
}

/// Everything KeyboardModel reaches outside itself, except the text host.
struct KeyboardDeps {
    var api: () -> KeyboardAPI
    var store: KeyboardStore
    var pasteboard: Pasteboard
    var now: () -> Date
    var sleep: (Duration) async throws -> Void
    /// The phone's calendar and reminders, for smart chips.
    var writer: SmartWriter = EventKitWriter()
    /// The voice for "Play with voice". Only a tap starts it; tests pass a silent fake.
    var speaker: @MainActor () -> Speaker = { SystemSpeaker() }

    static func live() -> KeyboardDeps {
        KeyboardDeps(api: { APIClient.shared() }, store: SharedKeyboardStore(), pasteboard: UIPasteboard.general,
                     now: Date.init, sleep: { try await Task.sleep(for: $0) })
    }
}
