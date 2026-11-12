import Foundation

/// A session from the server: a short access token and a rotating refresh token.
struct TokenPair: Decodable, Equatable {
    let access_token: String
    let refresh_token: String
    let expires_in: Int
}

/// What the Account screen shows.
struct AccountInfo: Decodable, Equatable {
    let email: String?
    let email_verified: Bool
    let apple: Bool
    let password: Bool
    let anonymous: Bool
}

/// `recovered`: this Apple account already had a Pip account from an earlier install. The tokens are then that account's.
struct AppleLinkResponse: Decodable, Equatable {
    let linked: Bool
    let recovered: Bool
    var access_token: String? = nil
    var refresh_token: String? = nil
    var expires_in: Int? = nil
    var tokens: TokenPair? {
        guard let a = access_token, let r = refresh_token else { return nil }
        return TokenPair(access_token: a, refresh_token: r, expires_in: expires_in ?? 900)
    }
}

/// The session tokens in the shared Keychain. The app writes them; the keyboard reads them and may refresh them.
enum TokenStore {
    static var access: String? { Keychain.get(.accessToken) }

    /// Writes both tokens and reads them back. False when the Keychain refused.
    @discardableResult
    static func save(_ p: TokenPair) -> Bool {
        let a = Keychain.set(.accessToken, p.access_token), r = Keychain.set(.refreshToken, p.refresh_token)
        return a == errSecSuccess && r == errSecSuccess && Keychain.get(.accessToken) == p.access_token
    }

    static func clear() {
        Keychain.set(.accessToken, nil)
        Keychain.set(.refreshToken, nil)
    }
}

/// Refreshes the access token under a file lock in the App Group, so the app and the keyboard never spend one refresh
/// token twice (the server reads a second spend as theft and ends the session).
/// An flock on `refresh.lock` in the App Group, shared by the app and the keyboard. The wipe holds it too.
enum RefreshLock {
    static func open() -> Int32 { SharedStore.url(.refreshLock).map { Darwin.open($0.path, O_CREAT | O_RDWR, 0o600) } ?? -1 }

    /// Runs `body` holding the lock, or without it after `seconds`: a held lock never blocks a logout for long.
    static func held<T>(waitingAtMost seconds: Double, _ body: () throws -> T) rethrows -> T {
        let fd = open()
        var locked = false
        let end = Date().addingTimeInterval(seconds)
        while fd >= 0 {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { locked = true; break }
            if Date() >= end { break }
            usleep(20_000)
        }
        defer { if fd >= 0 { if locked { flock(fd, LOCK_UN) }; close(fd) } }
        return try body()
    }
}

enum TokenRefresher {
    static func refreshed(baseURL: String, replacing failed: String?, session: URLSession = .shared) async throws -> String {
        let fd = RefreshLock.open()
        if fd >= 0 { await Task.detached { _ = flock(fd, LOCK_EX) }.value }
        defer { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }
        let epoch = SharedStore.accountEpoch
        // The other process refreshed while this one waited: use its token.
        if let now = Keychain.get(.accessToken), now != failed { return now }
        guard let refresh = Keychain.get(.refreshToken) else { throw APIError.notPaired }
        do {
            let p: TokenPair = try await APIClient.post(baseURL: baseURL, "/v1/auth/refresh", ["refresh_token": refresh], session: session)
            // A logout happened meanwhile: these tokens belong to the last person, so they are dropped, not saved.
            guard SharedStore.accountEpoch == epoch else { throw APIError.notPaired }
            guard TokenStore.save(p) else { throw APIError.message("Could not save your sign-in on this phone. Try again.") }
            return p.access_token
        } catch APIError.http(401, _) {
            // The session ended elsewhere (log out everywhere, a reset, or a reused token).
            TokenStore.clear()
            throw APIError.notPaired
        }
    }
}

extension APIClient {
    /// A call with no token: sign-in, sign-up, codes and refresh.
    static func post<T: Decodable>(baseURL: String, _ path: String, _ body: [String: String], session: URLSession = .shared) async throws -> T {
        let (code, data) = try await postRaw(baseURL: baseURL, path, body, session: session)
        guard (200..<300).contains(code) else { throw APIError.http(code, String(decoding: data, as: UTF8.self)) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    static func postRaw(baseURL: String, _ path: String, _ body: [String: String], session: URLSession = .shared) async throws -> (Int, Data) {
        guard let url = URL(string: baseURL + path) else { throw APIError.message("Server address is wrong") }
        var r = URLRequest(url: url, timeoutInterval: 20)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONEncoder().encode(body)
        let (data, resp) = try await session.data(for: r)
        return ((resp as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    /// "Skip for now": a device account. `deviceID` is a random UUID from this phone's Keychain; the server makes a new user each time.
    static func deviceSignIn(baseURL: String, deviceID: String) async throws -> TokenPair {
        try await post(baseURL: baseURL, "/v1/auth/device", ["device_id": deviceID])
    }

    static func appleSignIn(baseURL: String, identityToken: String, nonce: String) async throws -> TokenPair {
        try await post(baseURL: baseURL, "/v1/auth/apple", ["identity_token": identityToken, "nonce": nonce])
    }

    /// Always "check your email" when the request is fine, whether or not the email has an account.
    static func emailSignUp(baseURL: String, email: String, password: String) async throws {
        let (code, data) = try await postRaw(baseURL: baseURL, "/v1/auth/email/signup", ["email": email, "password": password])
        guard code == 202 else { throw APIError.http(code, String(decoding: data, as: UTF8.self)) }
    }

    /// The password goes with the code: only the email's owner has the code, so their password is the one that counts.
    static func emailVerify(baseURL: String, email: String, code: String, password: String) async throws -> TokenPair {
        try await post(baseURL: baseURL, "/v1/auth/email/verify", ["email": email, "code": code, "password": password])
    }

    static func emailSignIn(baseURL: String, email: String, password: String) async throws -> TokenPair {
        try await post(baseURL: baseURL, "/v1/auth/email/login", ["email": email, "password": password])
    }

    static func forgotPassword(baseURL: String, email: String) async throws {
        let (code, data) = try await postRaw(baseURL: baseURL, "/v1/auth/password/forgot", ["email": email])
        guard code == 202 else { throw APIError.http(code, String(decoding: data, as: UTF8.self)) }
    }

    static func resetPassword(baseURL: String, email: String, code: String, password: String) async throws -> TokenPair {
        try await post(baseURL: baseURL, "/v1/auth/password/reset", ["email": email, "code": code, "password": password])
    }

    /// A build from before sessions kept a device token. It is traded once for a session.
    static func exchangeLegacy(baseURL: String, deviceToken: String) async throws -> TokenPair {
        try await post(baseURL: baseURL, "/v1/auth/device/exchange", ["device_token": deviceToken])
    }

    // MARK: signed-in account calls

    func account() async throws -> AccountInfo { try await send(request("GET", "/v1/me"), as: AccountInfo.self) }

    /// "Save your details": attaches the Apple account to this account. The server checks the identity token and the raw nonce.
    func linkApple(identityToken: String, nonce: String) async throws -> AppleLinkResponse {
        try await send(request("POST", "/v1/auth/apple/link", body: ["identity_token": identityToken, "nonce": nonce]), as: AppleLinkResponse.self)
    }

    func linkEmail(email: String, password: String) async throws {
        struct Out: Decodable { let status: String }
        _ = try await send(request("POST", "/v1/auth/email/link", body: ["email": email, "password": password]), as: Out.self)
    }

    func linkEmailVerify(code: String) async throws {
        struct Out: Decodable { let linked: Bool }
        _ = try await send(request("POST", "/v1/auth/email/link/verify", body: ["code": code]), as: Out.self)
    }

    func logout() async throws {
        struct Out: Decodable { let ok: Bool }
        _ = try await send(request("POST", "/v1/auth/logout"), as: Out.self)
    }

    func logoutEverywhere() async throws {
        struct Out: Decodable { let ok: Bool }
        _ = try await send(request("POST", "/v1/auth/logout-all"), as: Out.self)
    }

    /// An account with a password sends it; others send only the confirm.
    func deleteAccount(password: String?) async throws {
        struct Body: Encodable { let password: String?; let confirm: Bool? }
        struct Out: Decodable { let deleted: Bool }
        let body = password.map { Body(password: $0, confirm: nil) } ?? Body(password: nil, confirm: true)
        _ = try await send(request("DELETE", "/v1/account", body: body), as: Out.self)
    }
}
