import Foundation

/// One of today's calendar events, cut down to what the keyboard may see: time and title.
struct Appointment: Codable, Equatable, Identifiable {
    let start: Date
    let end: Date
    let title: String

    var id: String { "\(start.timeIntervalSince1970)|\(title)" }
    var time: String {
        let f = DateFormatter()
        f.dateFormat = "h:mm"
        return f.string(from: start)
    }
}

struct Note: Codable, Equatable, Identifiable {
    var id = UUID()
    var text: String
    /// Typing this, then space or return, puts the note in the message. Nil means no shortcut.
    var trigger: String?

    static let demo = [
        Note(text: "On my way, see you in 10 minutes!", trigger: ";omw"),
        Note(text: "Thanks for reaching out. I'll get back to you today."),
    ]
}

/// A built-in keyboard action. The owner can change its trigger or turn it off.
struct ActionShortcut: Codable, Equatable, Identifiable {
    enum Action: String, Codable, CaseIterable { case fix }
    let action: Action
    var trigger: String
    var enabled = true

    var id: String { action.rawValue }
    var title: String { "Fix typos" }
    /// How to type it, with the current trigger.
    var usage: String { trigger }
    var detail: String { "Fixes typos, capitals and spacing before the cursor, on your phone. If it finds none, it checks the grammar." }

    static let defaults = [ActionShortcut(action: .fix, trigger: ";fix")]
}

enum Shortcuts {
    /// Triggers are one lowercase word.
    static func normalize(_ raw: String) -> String {
        raw.lowercased().filter { !$0.isWhitespace }
    }

    /// Nil when the trigger can be saved. `taken` holds every other trigger.
    static func problem(_ trigger: String, taken: Set<String>) -> String? {
        if trigger.count < 2 { return "Use 2 characters or more." }
        if trigger.count > 20 { return "Use 20 characters or fewer." }
        if taken.contains(trigger) { return "Another shortcut uses \(trigger)." }
        return nil
    }
}

/// A visual explanation the owner exported from the keyboard. The PNG (and the scene, for Replay) sit next to the list in the App Group.
struct Drawing: Codable, Identifiable, Equatable {
    let id: UUID
    let title: String
    let created: Date
    let file: String
    /// The scene JSON file, so Home can replay the drawing. Older drawings have none.
    var sceneFile: String? = nil
}

/// Something Pip explained when the owner tapped it: a word ("btw"), an answer or a chart. Home counts today's.
struct Learned: Codable, Equatable, Identifiable {
    enum Kind: String, Codable { case word, answer, chart }
    var id: String { "\(kind.rawValue)|\(subject)" }
    let subject: String
    let line: String
    let kind: Kind
    let date: Date
}

/// A plan the keyboard read in a chat ("quiz on friday 9 am") and showed as a chip. Home offers to add the ones not added yet.
struct Caught: Codable, Equatable, Identifiable {
    enum Place: String, Codable { case calendar, reminder }
    let title: String
    let place: Place
    let date: Date
    /// Nil for an all-day event or a reminder.
    let end: Date?
    let seen: Date
    var id: String { "\(place.rawValue)|\(title.lowercased())|\(Int(date.timeIntervalSince1970))" }
}
