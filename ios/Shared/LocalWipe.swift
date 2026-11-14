import Foundation
import WebKit

/// Removes everything the previous person left on this phone. The app runs both parts on logout and account delete.
/// The keyboard runs `wipeProcess` itself the next time it appears, because its caches live in its own sandbox.
enum LocalWipe {
    /// What the app and the keyboard share: the Keychain group, every App Group file and every App Group default,
    /// except the NEAR pay key (Keychain) and its public key (App Group). `PayKeyVault.forget` removes those.
    /// Ends by writing a new account epoch, which tells the keyboard to drop what it holds in memory.
    static func wipeShared() {
        // Take the refresh lock when it is free within a second, so a refresh cannot write the last person's tokens back
        // between its epoch check and its save. A refresh still running sees the new epoch and drops its tokens.
        RefreshLock.held(waitingAtMost: 1) {
            wipeSharedLocked()
        }
    }

    private static func wipeSharedLocked() {
        // The NEAR pay key and its public key stay: losing them loses the money in the account.
        let payKey = SharedStore.payPublicKey
        Keychain.deleteAllButPayKey()
        if let root = SharedStore.container {
            // Library/Preferences holds the App Group defaults, cleared below key by key. The lock file stays: deleting a file
            // another process holds locked would break the lock.
            empty(root, keep: ["Library", StoreFile.refreshLock.rawValue])
            empty(root.appendingPathComponent("Library"), keep: ["Preferences"])
        }
        if let d = SharedStore.defaults {
            // Key by key: removePersistentDomain on a shared suite can drop the next writes, and the keyboard reads this suite live.
            for key in d.dictionaryRepresentation().keys { d.removeObject(forKey: key) }
            for key in StoreKey.allCases { d.removeObject(forKey: key.rawValue) }
            d.synchronize()
        }
        SharedStore.defaults?.set(true, forKey: StoreKey.installed.rawValue)
        SharedStore.payPublicKey = payKey
        SharedStore.accountEpoch = UUID().uuidString
    }

    /// What this process alone holds: URL cache, cookies, web data of every type, temp files, caches, and its own defaults.
    @MainActor
    static func wipeProcess() async {
        await clearURLCache()
        for jar in [HTTPCookieStorage.shared, HTTPCookieStorage.sharedCookieStorage(forGroupContainerIdentifier: AppConfig.appGroupID)] {
            jar.removeCookies(since: .distantPast)
            for c in jar.cookies ?? [] { jar.deleteCookie(c) }
        }
        let web = WKWebsiteDataStore.default()
        await web.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        let fm = FileManager.default
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)
        for dir in [fm.temporaryDirectory] + caches { empty(dir) }
        if let id = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: id) }
    }

    /// URLCache clears on a background queue and has no completion. Zero capacity makes it drop what it holds, and
    /// URLSession.shared.reset (the only session the app uses; it shares this cache) returns once its caches are flushed.
    /// Without the wait, a response stored just before logout could land after the clear, and SQLite's truncate scratch
    /// files (tmpsqlitetruncatedb*) appeared in tmp after the folder was emptied.
    @MainActor
    private static func clearURLCache() async {
        let cache = URLCache.shared
        let (memory, disk) = (cache.memoryCapacity, cache.diskCapacity)
        cache.removeAllCachedResponses()
        cache.memoryCapacity = 0
        cache.diskCapacity = 0
        await URLSession.shared.reset()
        cache.memoryCapacity = memory
        cache.diskCapacity = disk
    }

    /// Every file and folder in `dir`, one by one, except `keep` and iOS's own container record
    /// (".com.apple.mobile_container_manager.metadata.plist"). Deleting that record broke the keyboard in Muninn.
    static func empty(_ dir: URL, keep: Set<String> = []) {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where !keep.contains(name) && !name.hasPrefix(".com.apple.") {
            try? fm.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    /// Logout and account delete on the app side: the shared stores, then this process.
    @MainActor
    static func wipeAll() async {
        wipeShared()
        await sharedDefaultsReachDisk()
        await wipeProcess()
    }

    /// cfprefsd writes the App Group plist to disk on its own schedule, so the last person's values could still sit in the
    /// file when logout returns. Wait, at most two seconds, until the file holds only the keys the wipe keeps.
    @MainActor
    private static func sharedDefaultsReachDisk() async {
        guard let file = SharedStore.container?.appendingPathComponent("Library/Preferences/\(AppConfig.appGroupID).plist") else { return }
        let kept: Set<String> = [StoreKey.accountEpoch.rawValue, StoreKey.installed.rawValue, StoreKey.payPublicKey.rawValue]
        for _ in 0..<100 {
            guard let data = FileManager.default.contents(atPath: file.path),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  !Set(plist.keys).isSubset(of: kept) else { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
