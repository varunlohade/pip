import Combine
import SwiftUI

@main
struct PipApp: App {
    @StateObject private var session = Session()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
                .onOpenURL { session.handle(url: $0) }
        }
    }
}

@MainActor
final class Session: ObservableObject {
    @Published var paired = SharedStore.signedIn
    /// True from a fresh start until the last onboarding step. A signed-in relaunch starts false, so onboarding never shows again.
    @Published var onboarding = !SharedStore.signedIn
    /// After a wipe (logout, delete, a refused session), onboarding opens at the sign-in step, not the intro.
    @Published var signInNext = false
    @Published var serverURL = SharedStore.serverURL
    @Published var error: String?
    /// The account is saved with Apple. Until then Home offers it.
    @Published var appleLinked = SharedStore.appleLinked
    /// One quiet line after a link, such as "Welcome back".
    @Published var notice: String?
    /// Goes up when the account behind the app changes (sign-in, logout, a recovered account), so Home loads again
    /// and the navigation stack starts new.
    @Published var account = 0
    /// A payment waiting on the approval card: from a pip://approve/<id> link, or left by the keyboard in the App Group.
    @Published var approval: PayApprovalRequest?
    /// pip://pin-setup from the keyboard's "Set a payment PIN in Pip": Pip Pay opens and asks for the PIN.
    @Published var pinSetup = false
    private var rejected: AnyCancellable?
    private var signingOut = false

    init() {
        SharedStore.dropSecretsFromAnEarlierInstall()
        paired = SharedStore.signedIn
        onboarding = !SharedStore.signedIn
        rejected = NotificationCenter.default.publisher(for: APIClient.tokenRejected)
            .map { $0.userInfo?["epoch"] as? String }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] epoch in Task { await self?.tokenRejected(epoch: epoch) } }
    }

    /// The server refused this phone's session (it expired or ended elsewhere): the same wipe as log out, then sign-in.
    /// An answer to a call from before the last wipe or sign-in, or a second one while the wipe runs, does nothing.
    func tokenRejected(epoch: String?) async {
        guard !signingOut, paired, epoch == SharedStore.accountEpoch else { return }
        signingOut = true
        await LocalWipe.wipeAll()
        reset()
        signingOut = false
    }

    /// The server for sign-in. UI tests point a fresh install at the fake server: "-serverURL http://127.0.0.1:8799".
    var server: String {
        #if DEBUG
        if let test = UserDefaults.standard.string(forKey: "serverURL") { return test }
        #endif
        return SharedStore.serverURL
    }

    /// A build from before sessions kept a long-lived device token. Trade it once for a session, so nobody has to sign in again.
    func migrateLegacyToken() async {
        guard let old = Keychain.get(.legacyDeviceToken) else { return }
        if let p = try? await APIClient.exchangeLegacy(baseURL: server, deviceToken: old), save(p, server: server) {
            Keychain.set(.legacyDeviceToken, nil)
            onboarding = false
        } else if !SharedStore.signedIn {
            // The server no longer knows it: drop it, so the phone does not keep a dead secret.
            Keychain.set(.legacyDeviceToken, nil)
        }
    }

    /// One plain line for a failed sign-in call. Wrong password and unknown email read the same, as the server sends them.
    nonisolated static func line(_ e: Error) -> String {
        switch e {
        case APIError.http(429, _): return "Too many tries. Wait a while, then try again."
        case APIError.http(let code, let body) where (400..<500).contains(code): return serverWords(body) ?? "That did not work. Try again."
        case is APIError: return "That did not work. Try again."
        default: return "Cannot reach \(AppConfig.displayName). Check your connection and try again."
        }
    }

    /// Runs one sign-in call; on success the tokens go to the Keychain. Returns an error line, or nil when signed in.
    func signIn(_ call: () async throws -> TokenPair) async -> String? {
        do {
            let p = try await call()
            return save(p, server: server) ? nil : (error ?? "Could not save your sign-in on this phone. Try again.")
        } catch {
            return Self.line(error)
        }
    }

    /// "Skip for now": the server makes a device account. It can be saved with Apple or an email later.
    func getStarted() async -> Bool {
        let line = await signIn { try await APIClient.deviceSignIn(baseURL: server, deviceID: SharedStore.deviceID) }
        error = line
        return line == nil
    }

    func signInWithApple(identityToken: String, nonce: String) async -> String? {
        let line = await signIn { try await APIClient.appleSignIn(baseURL: server, identityToken: identityToken, nonce: nonce) }
        if line == nil { SharedStore.appleLinked = true; appleLinked = true }
        return line
    }

    /// What the owner reads after "Continue with Apple". A recovered account says so.
    nonisolated static func linkNotice(_ r: AppleLinkResponse) -> String {
        r.recovered ? "Welcome back. Your account is here again." : "Saved \u{2713} Your account is safe with your Apple account."
    }

    /// "To save your details, continue with Apple": links the Apple account to this account.
    /// If the Apple account had an earlier account, the server sends that account's tokens and the app switches to it.
    func linkApple(identityToken: String, nonce: String) async -> String? {
        do {
            let r = try await APIClient.shared().linkApple(identityToken: identityToken, nonce: nonce)
            if r.recovered {
                guard let p = r.tokens, save(p, server: SharedStore.serverURL) else { return "Could not save your account on this phone. Try again." }
            }
            SharedStore.appleLinked = true
            appleLinked = true
            notice = Self.linkNotice(r)
            return nil
        } catch APIError.http(409, let body) {
            return plainLine(APIError.http(409, body))
        } catch {
            return Self.line(error)
        }
    }

    #if DEBUG
    /// Developer path, Debug builds only: pair with a refresh token from `npm run device`, or a fake server token.
    @discardableResult
    func pair(token: String, server: String) async -> Bool {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let server = server.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        do {
            let p: TokenPair
            if token.hasPrefix("prt_") {
                p = try await APIClient.post(baseURL: server, "/v1/auth/refresh", ["refresh_token": token])
            } else {
                try await APIClient(baseURL: server, token: token).me()
                p = TokenPair(access_token: token, refresh_token: "", expires_in: 0)
            }
            if p.refresh_token.isEmpty {
                LocalWipe.wipeShared()
                SharedStore.serverURL = server
                Keychain.set(.accessToken, p.access_token)
                return finishSave(server: server)
            }
            return save(p, server: server)
        } catch {
            self.error = "Pairing failed: \(error.localizedDescription)"
            return false
        }
    }
    #endif

    /// A new person on this phone starts from a clean phone, then the tokens go to the Keychain and are read back.
    /// A failed write shows an error; it never passes silently.
    private func save(_ p: TokenPair, server: String) -> Bool {
        LocalWipe.wipeShared()
        ApproverKeychain().set(nil)
        SharedStore.serverURL = server
        guard TokenStore.save(p) else {
            error = "Could not save your account on this phone. Try again."
            return false
        }
        return finishSave(server: server)
    }

    private func finishSave(server: String) -> Bool {
        serverURL = server
        error = nil
        appleLinked = SharedStore.appleLinked
        account += 1
        paired = true
        return true
    }

    func finishOnboarding() { onboarding = false; signInNext = false }

    enum Leave: Equatable { case logout, everywhere, delete(password: String?) }

    /// Logout, log out everywhere and delete account. The server call comes first; then the phone forgets everything but the pay key.
    /// A plain logout still wipes the phone when the server cannot be reached (the session then just expires there).
    /// Log out everywhere and delete must reach the server, or nothing changes and the owner sees why.
    func leave(_ how: Leave) async -> String? {
        let api = APIClient.shared()
        do {
            switch how {
            case .logout: try await api.logout()
            case .everywhere: try await api.logoutEverywhere()
            case .delete(let password): try await api.deleteAccount(password: password)
            }
        } catch APIError.notPaired where how == .logout {
        } catch APIError.http(401, _) where how == .logout {
        } catch {
            if how != .logout { return Self.line(error) }
        }
        await LocalWipe.wipeAll()
        // Logout keeps the NEAR pay key (it has no backup). Deleting the account removes it, after the balance warning.
        if case .delete = how { PayKeyVault().forget() }
        reset()
        return nil
    }

    private func reset() {
        ApproverKeychain().set(nil)
        approval = nil
        appleLinked = false
        notice = nil
        error = nil
        account += 1
        signInNext = true
        onboarding = true
        paired = false
    }

    /// Dev only: `xcrun simctl openurl <sim> "pip-dev://pair?token=...&server=..."`. It goes straight to Home.
    /// Release builds ignore it, so no web page can pair the app to another server.
    func handle(url: URL) {
        if let id = PayApprovalRequest(url: url)?.id {
            if SharedStore.payPending == id { SharedStore.payPending = nil }
            approval = PayApprovalRequest(id: id)
            return
        }
        if url.scheme == "pip", url.host == "pin-setup" {
            pinSetup = true
            return
        }
        #if DEBUG
        guard url.scheme == "pip-dev", url.host == "pair",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let token = items.first(where: { $0.name == "token" })?.value else { return }
        let server = items.first(where: { $0.name == "server" })?.value ?? AppConfig.defaultServerURL
        Task { if await pair(token: token, server: server) { finishOnboarding() } }
        #endif
    }
}

struct RootView: View {
    @EnvironmentObject var session: Session
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            Group {
                if session.paired && !session.onboarding { HomeView().transition(.opacity) } else { OnboardingView().transition(.opacity) }
            }
            .background(Theme.Color.bg.ignoresSafeArea())
        }
        // A new stack whenever the account changes (sign-in, logout, a 401, a recovered account), so no screen of the last
        // person (such as Account) stays pushed.
        .id(session.account)
        // Back from Settings: onboarding and Home see the new keyboard state at once.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            KeyboardSetup.shared.refresh()
            // Opened by hand after the keyboard said "Open Pip to approve": show that payment.
            if session.paired, let id = SharedStore.payPending {
                SharedStore.payPending = nil
                session.approval = PayApprovalRequest(id: id)
            }
        }
        .sheet(item: $session.approval) { r in ApprovalSheet(model: ApprovalModel.live(id: r.id)) }
        .sheet(isPresented: $session.pinSetup) { NavigationStack { PaySetup() } }
        .task { await session.migrateLegacyToken() }
    }
}

/// The id of a payment to approve. Only a 32-hex id from pip://approve/<id> is taken; the card reads every field from the server.
struct PayApprovalRequest: Identifiable, Equatable {
    let id: String

    init(id: String) { self.id = id }

    init?(url: URL) {
        guard url.scheme == "pip", url.host == "approve", url.pathComponents.count == 2 else { return nil }
        let id = url.pathComponents[1]
        guard id.count == 32, id.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return nil }
        self.id = id
    }
}
