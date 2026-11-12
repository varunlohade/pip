import Foundation
import Security

/// Device token lives in the shared Keychain group. Server URL lives in the App Group defaults.
/// The main app writes both. The keyboard only reads them.
enum SharedStore {
    private static let service = "com.orseliyas.pip.device"
    private static let account = "device_token"
    private static let serverKey = "server_url"
    private static let pasteboardKey = "pasteboard_change_count"
    private static let keyboardSeenKey = "keyboard_last_seen"

    private static var defaults: UserDefaults? { UserDefaults(suiteName: AppConfig.appGroupID) }

    static var serverURL: String {
        get { defaults?.string(forKey: serverKey) ?? AppConfig.defaultServerURL }
        set { defaults?.set(newValue, forKey: serverKey) }
    }

    /// The last pasteboard changeCount the keyboard used, so one copy is sent at most once.
    static var lastPasteboardChange: Int {
        get { defaults?.integer(forKey: pasteboardKey) ?? 0 }
        set { defaults?.set(newValue, forKey: pasteboardKey) }
    }

    /// The owner saved this account with Apple, so the "save your details" card stays away.
    static var appleLinked: Bool {
        get { defaults?.bool(forKey: "apple_linked") ?? false }
        set { defaults?.set(newValue, forKey: "apple_linked") }
    }

    /// Set by the keyboard each time it appears with Full Access, so the app can say "Keyboard is on".
    static var keyboardLastSeen: Date? {
        get { defaults?.object(forKey: keyboardSeenKey) as? Date }
        set { defaults?.set(newValue, forKey: keyboardSeenKey) }
    }

    /// Small JSON files in the App Group container. They stay on the device, encrypted while it is locked.
    static func load<T: Decodable>(_ type: T.Type, file: String) -> T? {
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppConfig.appGroupID)?.appendingPathComponent(file),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func save<T: Encodable>(_ value: T, file: String) {
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppConfig.appGroupID)?.appendingPathComponent(file),
              let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtection])
    }

    /// Today's appointments, written by the main app from the calendar. The keyboard only reads them.
    static var appointments: [Appointment] {
        get { (load([Appointment].self, file: "appointments.json") ?? []).filter { Calendar.current.isDateInToday($0.start) } }
        set { save(newValue, file: "appointments.json") }
    }

    /// The owner's notes. Both the app and the keyboard read and write them.
    static var notes: [Note] {
        get { load([Note].self, file: "notes.json") ?? Note.demo }
        set { save(newValue, file: "notes.json") }
    }

    /// Built-in action shortcuts with the owner's triggers. A new built-in action appears with its default.
    static var actionShortcuts: [ActionShortcut] {
        get {
            let saved = load([ActionShortcut].self, file: "shortcuts.json") ?? []
            return ActionShortcut.defaults.map { d in saved.first { $0.action == d.action } ?? d }
        }
        set { save(newValue, file: "shortcuts.json") }
    }

    // MARK: drawings: visual explanations the keyboard exported. PNGs in drawings/, the list in drawings.json.

    static var drawings: [Drawing] {
        get { load([Drawing].self, file: "drawings.json") ?? [] }
        set { save(newValue, file: "drawings.json") }
    }

    static func drawingURL(_ d: Drawing) -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppConfig.appGroupID)?
            .appendingPathComponent("drawings", isDirectory: true).appendingPathComponent(d.file)
    }

    /// Newest first, at most 30: the oldest file goes when a new one comes.
    static func saveDrawing(_ png: Data, title: String) throws {
        let d = Drawing(id: UUID(), title: title, created: Date(), file: UUID().uuidString + ".png")
        guard let url = drawingURL(d) else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: url, options: [.atomic, .completeFileProtection])
        var all = [d] + drawings
        for old in all.dropFirst(30) { if let u = drawingURL(old) { try? FileManager.default.removeItem(at: u) } }
        all = Array(all.prefix(30))
        drawings = all
    }

    private static func baseQuery(_ account: String = account) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: AppConfig.keychainGroup,
        ]
    }

    static var deviceToken: String? {
        var q = baseQuery()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// A random id for this install, made on first use and kept in the shared Keychain. "Get started" sends it.
    static var deviceID: String {
        var q = baseQuery("device_id")
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data, let id = String(data: data, encoding: .utf8) { return id }
        let id = UUID().uuidString.lowercased()
        var add = baseQuery("device_id")
        add[kSecValueData as String] = Data(id.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
        return id
    }

    @discardableResult
    static func setDeviceToken(_ token: String?) -> OSStatus {
        SecItemDelete(baseQuery() as CFDictionary)
        guard let token else { return errSecSuccess }
        var q = baseQuery()
        q[kSecValueData as String] = Data(token.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(q as CFDictionary, nil)
    }
}
