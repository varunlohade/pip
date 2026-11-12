import WebKit
import XCTest
@testable import Pip

/// Logout on the real stores: seed every one, log out through Session (the same path as the Account screen), check each is empty.
@MainActor
final class WipeTests: XCTestCase {
    private let site = URL(string: "https://pip.example/v1/me")!
    static let containerRecord = ".com.apple.mobile_container_manager.metadata.plist"

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
        // iOS's own container record must survive every wipe: deleting it broke the keyboard in Muninn.
        // The simulator writes it; a stand-in is written only when it is missing, and removed again at the end.
        let record = try XCTUnwrap(SharedStore.container).appendingPathComponent(Self.containerRecord)
        let recordBefore = FileManager.default.contents(atPath: record.path)
        if recordBefore == nil { try Data("stand-in".utf8).write(to: record) }
        defer { if recordBefore == nil { try? FileManager.default.removeItem(at: record) } }
        let recordBytes = try XCTUnwrap(FileManager.default.contents(atPath: record.path))
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
        // Two keys stay on purpose: the new epoch, and the install marker (it holds no data about the person).
        for k in StoreKey.allCases where k != .accountEpoch && k != .installed { XCTAssertNil(d.object(forKey: k.rawValue), "App Group default \(k)") }
        XCTAssertNil(d.object(forKey: "some_old_key"), "an unknown App Group default")
        XCTAssertNotNil(SharedStore.accountEpoch)
        XCTAssertNotEqual(SharedStore.accountEpoch, oldEpoch, "a new epoch tells the keyboard")
        // The empty refresh lock file stays: deleting a file another process holds locked would break the lock.
        XCTAssertEqual(contents(SharedStore.container).filter { $0 != StoreFile.refreshLock.rawValue }, [Self.containerRecord, "Library"], "App Group files")
        XCTAssertEqual(FileManager.default.contents(atPath: record.path), recordBytes, "iOS's container record is untouched")
        if let lock = SharedStore.url(.refreshLock), FileManager.default.fileExists(atPath: lock.path) {
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: lock.path)[.size] as? Int, 0, "the lock file holds nothing")
        }
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

/// Answers /v1/auth/refresh with new tokens. While it answers, the app logs out (the race in the iOS review, F2).
final class RefreshDuringLogout: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        LocalWipe.wipeShared()
        let body = Data(#"{"access_token":"pat_last_person_new","refresh_token":"prt_last_person_new","expires_in":900}"#.utf8)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
final class WipeRaceTests: XCTestCase {
    func testARefreshThatFinishesAfterALogoutDoesNotSaveTheLastPersonsTokens() async {
        Keychain.set(.accessToken, "pat_last_person_old")
        Keychain.set(.refreshToken, "prt_last_person_old")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RefreshDuringLogout.self]
        do {
            _ = try await TokenRefresher.refreshed(baseURL: "https://pip.example", replacing: "pat_last_person_old", session: URLSession(configuration: config))
            XCTFail("the refresh must not succeed across a logout")
        } catch {
            guard case APIError.notPaired = error else { return XCTFail("unexpected \(error)") }
        }
        XCTAssertNil(Keychain.get(.accessToken))
        XCTAssertNil(Keychain.get(.refreshToken))
        XCTAssertEqual(Keychain.count(), 0)
    }

    /// iOS keeps Keychain items after an uninstall. A fresh install must not open as the person before.
    func testAFreshInstallDropsSecretsAnEarlierInstallLeft() async throws {
        await LocalWipe.wipeAll()
        let d = try XCTUnwrap(SharedStore.defaults)
        d.removePersistentDomain(forName: AppConfig.appGroupID)
        for k in StoreKey.allCases { d.removeObject(forKey: k.rawValue) }
        Keychain.set(.refreshToken, "prt_from_before_the_uninstall")
        SharedStore.dropSecretsFromAnEarlierInstall()
        XCTAssertFalse(SharedStore.signedIn)
        XCTAssertEqual(Keychain.count(), 0)
        XCTAssertTrue(d.bool(forKey: StoreKey.installed.rawValue))

        // An update from a build without the marker keeps the person signed in.
        d.removeObject(forKey: StoreKey.installed.rawValue)
        SharedStore.serverURL = "http://localhost:8787"
        Keychain.set(.refreshToken, "prt_current_person")
        SharedStore.dropSecretsFromAnEarlierInstall()
        XCTAssertEqual(Keychain.get(.refreshToken), "prt_current_person")
        Keychain.deleteAll()
    }
}

/// A server that answers every call with `code` (and a nonce on GET /v1/auth/apple/nonce).
final class StatusStub: URLProtocol {
    nonisolated(unsafe) static var code = 401
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let nonce = request.url?.path == "/v1/auth/apple/nonce"
        let resp = HTTPURLResponse(url: request.url!, statusCode: nonce ? 200 : Self.code, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((nonce ? #"{"nonce":"server-nonce-0123456789","expires_in_s":600}"# : #"{"error":"unauthorized"}"#).utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// The lessons the Muninn team found (docs/SECURITY-AUTH.md, "Compared with Muninn"), checked on Pip.
@MainActor
final class SessionEndTests: XCTestCase {
    private var stubbed: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StatusStub.self]
        return URLSession(configuration: config)
    }

    private func signedIn() -> Session {
        LocalWipe.wipeShared()
        SharedStore.serverURL = "http://127.0.0.1:9"
        Keychain.set(.accessToken, "pat_person_a")
        SharedStore.notes = [Note(text: "Person A's note", trigger: ";a")]
        return Session()
    }

    /// A 401 on a signed-in route (the session ended elsewhere) runs the logout wipe and opens sign-in, with a new stack.
    /// A 401 under /v1/auth/ (a wrong password) keeps the session.
    func testA401OutsideAuthWipesAndOpensSignIn() async throws {
        StatusStub.code = 401
        let session = signedIn()
        XCTAssertTrue(session.paired)
        let account = session.account
        let epoch = SharedStore.accountEpoch
        let api = APIClient(baseURL: SharedStore.serverURL, token: "pat_person_a", session: stubbed)

        _ = try? await api.linkEmail(email: "a@example.com", password: "wrong password here")
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(session.paired, "a 401 under /v1/auth/ keeps the session")
        XCTAssertEqual(SharedStore.accountEpoch, epoch)

        _ = try? await api.me()
        for _ in 0..<300 where session.paired { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(session.paired)
        XCTAssertTrue(session.onboarding)
        XCTAssertTrue(session.signInNext, "onboarding opens at sign-in, not the intro")
        XCTAssertGreaterThan(session.account, account, "RootView's .id(session.account) builds a new navigation stack")
        XCTAssertNil(Keychain.get(.accessToken))
        XCTAssertFalse(SharedStore.notes.contains { $0.text.contains("Person A") })
        XCTAssertNotEqual(SharedStore.accountEpoch, epoch, "one wipe, and the keyboard hears of it")
    }

    /// A late 401 for a call that began before the last wipe does not wipe the next person.
    func testALate401FromBeforeTheLastWipeDoesNothing() async throws {
        let session = signedIn()
        let old = SharedStore.accountEpoch
        LocalWipe.wipeShared()
        Keychain.set(.accessToken, "pat_person_b")
        NotificationCenter.default.post(name: APIClient.tokenRejected, object: nil, userInfo: old.map { ["epoch": $0] } ?? [:])
        for _ in 0..<20 { await Task.yield() }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(session.paired)
        XCTAssertEqual(Keychain.get(.accessToken), "pat_person_b")
        Keychain.deleteAll()
    }

    /// Logout also gives a new navigation stack and opens sign-in.
    func testLogoutResetsTheStackAndOpensSignIn() async {
        let session = signedIn()
        let account = session.account
        _ = await session.leave(.logout)
        XCTAssertGreaterThan(session.account, account)
        XCTAssertTrue(session.signInNext)
        session.finishOnboarding()
        XCTAssertFalse(session.signInNext)
    }

    /// The keyboard throws its model away after a wipe and builds a new one; with no wipe it keeps it.
    func testTheKeyboardRebuildsItsModelAfterAWipe() async {
        Keychain.set(.accessToken, "pat_person_a")
        var wiped = 0
        let deps = KeyboardDeps(api: { FakeAPI() }, store: SharedKeyboardStore(), pasteboard: FakePasteboard(),
                                now: Date.init, sleep: { _ in }, wipeProcess: { wiped += 1 })
        let model = KeyboardModel(deps: deps)
        model.host = FakeHost()
        model.keyboardAppeared()
        for _ in 0..<20 { await Task.yield() }
        let wipesBefore = wiped
        XCTAssertNil(model.replacementIfAccountChanged(), "no wipe, same model")
        model.explainCache["x"] = ExplainResponse(short: "x", body: "", visual_ok: false)

        LocalWipe.wipeShared()
        let fresh = model.replacementIfAccountChanged()
        XCTAssertNotNil(fresh)
        XCTAssertFalse(fresh === model)
        XCTAssertTrue(fresh?.explainCache.isEmpty ?? false)
        XCTAssertTrue(model.explainCache.isEmpty, "the old model let go of its state too")
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(wiped, wipesBefore + 1, "this process's caches were wiped once")
        XCTAssertNil(fresh?.replacementIfAccountChanged(), "the new model is current")
    }

    /// Sign in with Apple uses the server's one-time nonce when the server has one.
    func testTheAppleNonceComesFromTheServer() async {
        let nonce = await APIClient.appleNonce(baseURL: "http://127.0.0.1:9", session: stubbed)
        XCTAssertEqual(nonce, "server-nonce-0123456789")
        StatusStub.code = 404
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StatusStub.self]
        let none = await APIClient.appleNonce(baseURL: "http://127.0.0.1:9/old", session: URLSession(configuration: config))
        XCTAssertNil(none, "an older server has no nonce route; the phone then makes its own")
        StatusStub.code = 401
    }
}
