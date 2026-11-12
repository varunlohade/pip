import Foundation
import WebKit

/// Removes everything the previous person left on this phone. The app runs both parts on logout and account delete.
/// The keyboard runs `wipeProcess` itself the next time it appears, because its caches live in its own sandbox.
enum LocalWipe {
    /// What the app and the keyboard share: the Keychain group, every App Group file and every App Group default.
    /// Ends by writing a new account epoch, which tells the keyboard to drop what it holds in memory.
    static func wipeShared() {
        Keychain.deleteAll()
        let fm = FileManager.default
        if let root = SharedStore.container {
            for item in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
                if item.lastPathComponent == "Library" {
                    // Library/Preferences holds the App Group defaults, cleared below through UserDefaults; everything else goes.
                    for sub in (try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil)) ?? [] where sub.lastPathComponent != "Preferences" {
                        try? fm.removeItem(at: sub)
                    }
                } else {
                    try? fm.removeItem(at: item)
                }
            }
        }
        if let d = SharedStore.defaults {
            d.removePersistentDomain(forName: AppConfig.appGroupID)
            for key in StoreKey.allCases { d.removeObject(forKey: key.rawValue) }
            d.synchronize()
        }
        SharedStore.accountEpoch = UUID().uuidString
    }

    /// What this process alone holds: URL cache, cookies, web data of every type, temp files, caches, and its own defaults.
    @MainActor
    static func wipeProcess() async {
        URLCache.shared.removeAllCachedResponses()
        for jar in [HTTPCookieStorage.shared, HTTPCookieStorage.sharedCookieStorage(forGroupContainerIdentifier: AppConfig.appGroupID)] {
            jar.removeCookies(since: .distantPast)
            for c in jar.cookies ?? [] { jar.deleteCookie(c) }
        }
        let web = WKWebsiteDataStore.default()
        await web.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        let fm = FileManager.default
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)
        for dir in [fm.temporaryDirectory] + caches {
            for item in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] { try? fm.removeItem(at: item) }
        }
        if let id = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: id) }
    }

    /// Logout and account delete on the app side: the shared stores, then this process.
    @MainActor
    static func wipeAll() async {
        wipeShared()
        await wipeProcess()
    }
}
