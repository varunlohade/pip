import Foundation

/// Which shortcut, if any, the last word before the cursor triggers on space or return. Pure: the caller applies it.
enum ShortcutEngine {
    struct Match: Equatable {
        enum Action: Equatable {
            case insert(String)
            case fix
        }
        /// Characters to delete before the cursor first.
        let delete: Int
        let action: Action
        /// The last word, lowercased. The intro watches it.
        let trigger: String
    }

    static func match(before: String, notes: [Note], actions: [ActionShortcut]) -> Match? {
        let words = before.split(omittingEmptySubsequences: false, whereSeparator: \.isWhitespace)
        guard let last = words.last, last.count >= 2 else { return nil }
        let key = last.lowercased()

        if let note = notes.first(where: { $0.trigger == key }) {
            return Match(delete: last.count, action: .insert(note.text), trigger: key)
        }
        if let a = actions.filter(\.enabled).first(where: { $0.trigger == key }) {
            switch a.action {
            case .fix:
                let space = words.count > 1 && before.dropLast(last.count).last == " " ? 1 : 0
                return Match(delete: last.count + space, action: .fix, trigger: key)
            }
        }
        return nil
    }
}
