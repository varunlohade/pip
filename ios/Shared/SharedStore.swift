import Foundation
import Security

/// Every App Group UserDefaults key, in one place. Nothing secret goes here: secrets live in the Keychain (`Secret`).
enum StoreKey: String, CaseIterable {
    case serverURL = "server_url"
    /// The last pasteboard changeCount the keyboard used, so one copy is sent at most once.
    case lastPasteboardChange = "pasteboard_change_count"
    /// The account is saved with Apple, so the "save your details" card stays away.
    case appleLinked = "apple_linked"
    /// Set by the keyboard each time it appears with Full Access, so the app can say "Keyboard is on".
    case keyboardLastSeen = "keyboard_last_seen"
    /// A new random value after every logout wipe. The keyboard compares it with the one it last saw and drops what it holds.
    case accountEpoch = "account_epoch"
    /// The epoch the keyboard last acted on. The wipe clears it, so a fresh install and a wiped phone both start equal.
    case keyboardSeenEpoch = "keyboard_seen_epoch"
    /// Set on first launch. iOS deletes the App Group on uninstall but keeps the Keychain, so no marker means stale secrets.
    case installed = "installed"
}

/// Every App Group file, in one place. All are small JSON files, except the drawings folder.
enum StoreFile: String, CaseIterable {
    case appointments = "appointments.json"
    case notes = "notes.json"
    case shortcuts = "shortcuts.json"
    case drawings = "drawings.json"
    case learned = "learned.json"
    case caught = "caught.json"
    /// The last currency rates from /v1/rates, so conversions work offline.
    case rates = "rates.json"
    /// The cross-process lock for token refresh (see TokenRefresher). Empty.
    case refreshLock = "refresh.lock"
}

/// Every Keychain item, in one place. All are generic passwords in the shared access group, so the keyboard reads them too.
enum Secret: String, CaseIterable {
    /// The short-lived access token for the API.
    case accessToken = "access_token"
    /// The rotating refresh token.
    case refreshToken = "refresh_token"
    /// A long-lived device token from builds before sessions. Traded once for a session, then deleted.
    case legacyDeviceToken = "device_token"
    /// A random id for this install. "Skip for now" sends it.
    case deviceID = "device_id"
}

/// The Keychain, in the shared access group. Items open after the first unlock and never leave this device (no backup, no sync).
enum Keychain {
    static let service = "com.orseliyas.pip.device"

    private static func query(_ s: Secret) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: s.rawValue,
            kSecAttrAccessGroup as String: AppConfig.keychainGroup,
        ]
    }

    static func get(_ s: Secret) -> String? {
        var q = query(s)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func set(_ s: Secret, _ value: String?) -> OSStatus {
        SecItemDelete(query(s) as CFDictionary)
        guard let value else { return errSecSuccess }
        var q = query(s)
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(q as CFDictionary, nil)
    }

    /// Every generic password in the shared group, whatever its service or account, so nothing from an older build stays.
    static func deleteAll() {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccessGroup as String: AppConfig.keychainGroup]
        SecItemDelete(q as CFDictionary)
    }

    /// How many items the shared group holds. The wipe test reads it.
    static func count() -> Int {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccessGroup as String: AppConfig.keychainGroup,
                                kSecMatchLimit as String: kSecMatchLimitAll, kSecReturnAttributes as String: true]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return 0 }
        return (out as? [Any])?.count ?? 0
    }
}

/// The one storage layer the app and the keyboard share: App Group defaults (`StoreKey`), App Group files (`StoreFile`)
/// and the Keychain (`Secret`). Files are written with completeUntilFirstUserAuthentication, so the keyboard can read them
/// while the phone is locked after the first unlock.
enum SharedStore {
    static let protection: Data.WritingOptions = .completeFileProtectionUntilFirstUserAuthentication

    static var defaults: UserDefaults? { UserDefaults(suiteName: AppConfig.appGroupID) }
    static var container: URL? { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppConfig.appGroupID) }
    static func url(_ f: StoreFile) -> URL? { container?.appendingPathComponent(f.rawValue) }
    static var drawingsFolder: URL? { container?.appendingPathComponent("drawings", isDirectory: true) }

    static var serverURL: String {
        get { defaults?.string(forKey: StoreKey.serverURL.rawValue) ?? AppConfig.defaultServerURL }
        set { defaults?.set(newValue, forKey: StoreKey.serverURL.rawValue) }
    }

    static var lastPasteboardChange: Int {
        get { defaults?.integer(forKey: StoreKey.lastPasteboardChange.rawValue) ?? 0 }
        set { defaults?.set(newValue, forKey: StoreKey.lastPasteboardChange.rawValue) }
    }

    static var appleLinked: Bool {
        get { defaults?.bool(forKey: StoreKey.appleLinked.rawValue) ?? false }
        set { defaults?.set(newValue, forKey: StoreKey.appleLinked.rawValue) }
    }

    static var keyboardLastSeen: Date? {
        get { defaults?.object(forKey: StoreKey.keyboardLastSeen.rawValue) as? Date }
        set { defaults?.set(newValue, forKey: StoreKey.keyboardLastSeen.rawValue) }
    }

    static var accountEpoch: String? {
        get { defaults?.string(forKey: StoreKey.accountEpoch.rawValue) }
        set { defaults?.set(newValue, forKey: StoreKey.accountEpoch.rawValue) }
    }

    static var keyboardSeenEpoch: String? {
        get { defaults?.string(forKey: StoreKey.keyboardSeenEpoch.rawValue) }
        set { defaults?.set(newValue, forKey: StoreKey.keyboardSeenEpoch.rawValue) }
    }

    static func load<T: Decodable>(_ type: T.Type, _ f: StoreFile) -> T? {
        guard let url = url(f), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func save<T: Encodable>(_ value: T, _ f: StoreFile) {
        guard let url = url(f), let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: [.atomic, protection])
    }

    /// Today's appointments, written by the main app from the calendar. The keyboard only reads them.
    static var appointments: [Appointment] {
        get { (load([Appointment].self, .appointments) ?? []).filter { Calendar.current.isDateInToday($0.start) } }
        set { save(newValue, .appointments) }
    }

    /// The owner's notes. Both the app and the keyboard read and write them.
    static var notes: [Note] {
        get { load([Note].self, .notes) ?? Note.demo }
        set { save(newValue, .notes) }
    }

    /// Built-in action shortcuts with the owner's triggers. A new built-in action appears with its default.
    static var actionShortcuts: [ActionShortcut] {
        get {
            let saved = load([ActionShortcut].self, .shortcuts) ?? []
            return ActionShortcut.defaults.map { d in saved.first { $0.action == d.action } ?? d }
        }
        set { save(newValue, .shortcuts) }
    }

    // MARK: drawings: visual explanations the keyboard exported. PNGs in drawings/, the list in drawings.json.

    static var drawings: [Drawing] {
        get { load([Drawing].self, .drawings) ?? [] }
        set { save(newValue, .drawings) }
    }

    static func drawingURL(_ d: Drawing) -> URL? { drawingsFolder?.appendingPathComponent(d.file) }

    static func drawingSceneURL(_ d: Drawing) -> URL? {
        d.sceneFile.flatMap { f in drawingsFolder?.appendingPathComponent(f) }
    }

    /// Newest first, at most 30: the oldest files go when a new one comes.
    static func saveDrawing(_ png: Data, title: String, scene: Data?) throws {
        let base = UUID().uuidString
        let d = Drawing(id: UUID(), title: title, created: Date(), file: base + ".png", sceneFile: scene == nil ? nil : base + ".json")
        guard let url = drawingURL(d) else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        try png.write(to: url, options: [.atomic, protection])
        if let scene, let sceneURL = drawingSceneURL(d) { try scene.write(to: sceneURL, options: [.atomic, protection]) }
        var all = [d] + drawings
        for old in all.dropFirst(30) {
            for u in [drawingURL(old), drawingSceneURL(old)].compactMap({ $0 }) { try? FileManager.default.removeItem(at: u) }
        }
        all = Array(all.prefix(30))
        drawings = all
    }

    /// What the owner looked up in the keyboard, newest first, kept for 30 days.
    static var learned: [Learned] {
        get { load([Learned].self, .learned) ?? [] }
        set { save(Array(newValue.filter { $0.date > Date().addingTimeInterval(-30 * 86_400) }.prefix(200)), .learned) }
    }

    /// Plans the keyboard read in chats, newest first; one disappears once it is added.
    static var caught: [Caught] {
        get { load([Caught].self, .caught) ?? [] }
        set { save(Array(newValue.filter { $0.seen > Date().addingTimeInterval(-7 * 86_400) }.prefix(20)), .caught) }
    }

    static var currencyRates: Calc.Rates? {
        get { load(Calc.Rates.self, .rates) }
        set { if let newValue { save(newValue, .rates) } }
    }

    // MARK: secrets

    /// Keychain items outlive an uninstall. A fresh install (no marker, no App Group data) drops what an earlier install left,
    /// so the next person never opens as the last one. An update from a build without the marker keeps its data.
    static func dropSecretsFromAnEarlierInstall() {
        guard let d = defaults, !d.bool(forKey: StoreKey.installed.rawValue) else { return }
        let hasData = StoreKey.allCases.contains { d.object(forKey: $0.rawValue) != nil }
            || StoreFile.allCases.contains { $0 != .refreshLock && (url($0).map { FileManager.default.fileExists(atPath: $0.path) } ?? false) }
        if !hasData { Keychain.deleteAll() }
        d.set(true, forKey: StoreKey.installed.rawValue)
    }

    /// Signed in: the Keychain holds a session (or a dev pairing token).
    static var signedIn: Bool { Keychain.get(.accessToken) != nil || Keychain.get(.refreshToken) != nil }

    /// A random id for this install, made on first use and kept in the shared Keychain.
    static var deviceID: String {
        if let id = Keychain.get(.deviceID) { return id }
        let id = UUID().uuidString.lowercased()
        Keychain.set(.deviceID, id)
        return id
    }
}
