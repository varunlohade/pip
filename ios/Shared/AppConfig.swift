import Foundation

/// Names and ids. The display name comes from PRODUCT_DISPLAY_NAME in project.yml.
enum AppConfig {
    /// The app name, also inside the keyboard extension.
    static var displayName: String {
        Bundle.main.object(forInfoDictionaryKey: "AppName") as? String ?? "Pip"
    }
    static var keyboardName: String {
        Bundle.main.object(forInfoDictionaryKey: "KeyboardName") as? String ?? displayName + " Keyboard"
    }
    static var appGroupID: String {
        Bundle.main.object(forInfoDictionaryKey: "AppGroupID") as? String ?? "group.com.orseliyas.pip"
    }
    static var keychainGroup: String {
        let prefix = Bundle.main.object(forInfoDictionaryKey: "AppIdentifierPrefix") as? String ?? ""
        return prefix + "com.orseliyas.pip.shared"
    }
    /// From the DEFAULT_SERVER_URL build setting: the local server in Debug, the hosted one in Release.
    static var defaultServerURL: String {
        Bundle.main.object(forInfoDictionaryKey: "DefaultServerURL") as? String ?? "http://localhost:8787"
    }
    static var demoServerURL: String? {
        (Bundle.main.object(forInfoDictionaryKey: "DemoServerURL") as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
    static let suggestDebounce: Duration = .milliseconds(350)
    /// The owner's headline, used on the first screen and wherever the app describes itself.
    static let tagline = "A friend in your keyboard"
    static let taglineLine = "Pip answers as you type, and draws the hard parts step by step."

}
