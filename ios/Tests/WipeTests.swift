import WebKit
import XCTest
@testable import Pip

/// Logout on the real stores: seed every one, log out through Session (the same path as the Account screen), check each is empty.
@MainActor
final class WipeTests: XCTestCase {
    private let site = URL(string: "https://pip.example/v1/me")!

    private func seedEverything() async throws {
        for s in Secret.allCases { XCTAssertEqual(Keychain.set(s, "seed-\(s.rawValue)"), errSecSuccess, "Keychain write \(s)") }
        let d = try XCTUnwrap(SharedStore.defaults)
        for k in StoreKey.allCases { d.set("seed", forKey: k.rawValue) }
        d.set("left by an older build", forKey: "some_old_key")
        SharedStore.notes = [Note(text: "Ana's pin is in the drawer", trigger: ";pin")]
        SharedStore.appointments = [Appointment(start: Date(), end: Date().addingTimeInterval(600), title: "Dentist")]
        SharedStore.actionShortcuts = ActionShortcut.defaults
        SharedStore.learned = [Learned(subject: "btw", line: "by the way", kind: .word, date: Date())]
        SharedStore.caught = [Caught(title: "Lunch with Ana", place: .calendar, date: Date(), end: nil, seen: Date())]
        try SharedStore.saveDrawing(Data([0x89, 0x50]), title: "log function", scene: Data("{}".utf8))
        try Data("x".utf8).write(to: XCTUnwrap(SharedStore.url(.refreshLock)))
        try Data("x".utf8).write(to: XCTUnwrap(SharedStore.container).appendingPathComponent("stray.bin"))
        let groupCaches = try XCTUnwrap(SharedStore.container).appendingPathComponent("Library/Caches", isDirectory: true)
        try FileManager.default.createDirectory(at: groupCaches, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: groupCaches.appendingPathComponent("preview.jpg"))

        let response = HTTPURLResponse(url: site, statusCode: 200, httpVersion: nil, headerFields: ["Cache-Control": "max-age=600"])!
        URLCache.shared.storeCachedResponse(CachedURLResponse(response: response, data: Data("{\"email\":\"ana@example.com\"}".utf8)), for: URLRequest(url: site))
        let cookie = try XCTUnwrap(HTTPCookie(properties: [.domain: "pip.example", .path: "/", .name: "sid", .value: "seed", .expires: Date().addingTimeInterval(3600)]))
        HTTPCookieStorage.shared.setCookie(cookie)
        HTTPCookieStorage.sharedCookieStorage(forGroupContainerIdentifier: AppConfig.appGroupID).setCookie(cookie)
        await WKWebsiteDataStore.default().httpCookieStore.setCookie(cookie)
        try Data("x".utf8).write(to: FileManager.default.temporaryDirectory.appendingPathComponent("share-preview.jpg"))
        let caches = try XCTUnwrap(FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first)
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: caches.appendingPathComponent("render.png"))
        UserDefaults.standard.set(true, forKey: "intro_seen")
    }

    private func webRecords() async -> Int {
        await WKWebsiteDataStore.default().dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()).count
    }

    private func contents(_ url: URL?) -> [String] {
        guard let url else { return [] }
        return ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
    }

    func testLogoutEmptiesEveryStore() async throws {
        try await seedEverything()
        // Every store really holds something, so an empty one afterwards means the wipe did it.
        XCTAssertGreaterThanOrEqual(Keychain.count(), Secret.allCases.count)
        XCTAssertTrue(SharedStore.signedIn)
        XCTAssertFalse(SharedStore.drawings.isEmpty)
        XCTAssertNotNil(URLCache.shared.cachedResponse(for: URLRequest(url: site)))
        XCTAssertFalse((HTTPCookieStorage.shared.cookies ?? []).isEmpty)
        let webBefore = await webRecords()
        XCTAssertGreaterThan(webBefore, 0)
        XCTAssertFalse(contents(FileManager.default.temporaryDirectory).isEmpty)
        let oldEpoch = SharedStore.accountEpoch

        // The server is not running in unit tests: a plain logout still wipes the phone.
        let session = Session()
        let line = await session.leave(.logout)
        XCTAssertNil(line)
        XCTAssertFalse(session.paired)

        XCTAssertEqual(Keychain.count(), 0, "Keychain")
        for s in Secret.allCases where s != .deviceID { XCTAssertNil(Keychain.get(s), "Keychain \(s)") }
        XCTAssertFalse(SharedStore.signedIn)
        let d = try XCTUnwrap(SharedStore.defaults)
        for k in StoreKey.allCases where k != .accountEpoch { XCTAssertNil(d.object(forKey: k.rawValue), "App Group default \(k)") }
        XCTAssertNil(d.object(forKey: "some_old_key"), "an unknown App Group default")
        XCTAssertNotNil(SharedStore.accountEpoch)
        XCTAssertNotEqual(SharedStore.accountEpoch, oldEpoch, "a new epoch tells the keyboard")
        XCTAssertEqual(contents(SharedStore.container), ["Library"], "App Group files")
        XCTAssertEqual(contents(SharedStore.container?.appendingPathComponent("Library")).filter { $0 != "Preferences" }, [], "App Group Library")
        XCTAssertEqual(SharedStore.notes, Note.demo, "notes fall back to the built-in examples")
        XCTAssertTrue(SharedStore.drawings.isEmpty && SharedStore.learned.isEmpty && SharedStore.caught.isEmpty && SharedStore.appointments.isEmpty)
        XCTAssertNil(URLCache.shared.cachedResponse(for: URLRequest(url: site)), "URLCache")
        XCTAssertEqual(HTTPCookieStorage.shared.cookies ?? [], [], "cookies")
        XCTAssertEqual(HTTPCookieStorage.sharedCookieStorage(forGroupContainerIdentifier: AppConfig.appGroupID).cookies ?? [], [], "group cookies")
        let webAfter = await webRecords()
        XCTAssertEqual(webAfter, 0, "WKWebsiteDataStore")
        XCTAssertEqual(contents(FileManager.default.temporaryDirectory), [], "temp files")
        XCTAssertEqual(contents(FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first), [], "caches")
        XCTAssertNil(UserDefaults.standard.object(forKey: "intro_seen"), "the app's own defaults")
    }

    /// The keyboard runs in its own process. It sees the new epoch the next time it appears and drops the last person's state.
    func testTheKeyboardForgetsThePreviousPersonOnItsNextAppearance() async throws {
        Keychain.set(.accessToken, "pat_previous_person")
        SharedStore.notes = [Note(text: "Previous person's note", trigger: ";prev")]
        var wiped = 0
        let host = FakeHost()
        let model = KeyboardModel(deps: KeyboardDeps(api: { FakeAPI() }, store: SharedKeyboardStore(), pasteboard: FakePasteboard(),
                                                     now: Date.init, sleep: { _ in }, wipeProcess: { wiped += 1 }))
        model.host = host
        model.keyboardAppeared()
        XCTAssertTrue(model.paired)
        XCTAssertEqual(model.notes.first?.text, "Previous person's note")
        model.explainCache["compound interest"] = ExplainResponse(short: "Interest on interest.", body: "", visual_ok: false)
        model.sharePrepared = (Data([1]), Data([2]))
        for _ in 0..<20 { await Task.yield() }
        let wipesBefore = wiped

        _ = await Session().leave(.logout)
        model.keyboardAppeared()
        for _ in 0..<20 { await Task.yield() }

        XCTAssertFalse(model.paired)
        XCTAssertFalse(model.notes.contains { $0.text.contains("Previous person") })
        XCTAssertTrue(model.explainCache.isEmpty)
        XCTAssertNil(model.sharePrepared)
        XCTAssertEqual(wiped, wipesBefore + 1, "the keyboard wiped its own caches")
        model.keyboardAppeared()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(wiped, wipesBefore + 1, "once per logout, not on every appearance")
    }
}
