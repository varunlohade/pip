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
    @Published var paired = SharedStore.deviceToken != nil
    /// True from a fresh start until the last onboarding step. A signed-in relaunch starts false, so onboarding never shows again.
    @Published var onboarding = SharedStore.deviceToken == nil
    @Published var serverURL = SharedStore.serverURL
    @Published var error: String?
    /// The account is saved with Apple. Until then Home offers it.
    @Published var appleLinked = SharedStore.appleLinked
    /// One quiet line after a link, such as "Welcome back".
    @Published var notice: String?
    /// Goes up when the account behind the app changes, so Home loads again.
    @Published var account = 0

    /// "Get started": the server makes a device account and returns its token. No sign-in, and the token never shows on screen.
    func getStarted() async -> Bool {
        var server = SharedStore.serverURL
        #if DEBUG
        // UI tests point a fresh install at the fake server: "-serverURL http://127.0.0.1:8799".
        if let test = UserDefaults.standard.string(forKey: "serverURL") { server = test }
        #endif
        do {
            return save(token: try await APIClient.deviceSignIn(baseURL: server, deviceID: SharedStore.deviceID), server: server)
        } catch APIError.http(429, _) {
            error = "Too many tries. Wait a while, then try again."
        } catch is APIError {
            error = "That did not work. Try again."
        } catch {
            self.error = "Cannot reach \(AppConfig.displayName). Check your connection and try again."
        }
        return false
    }

    /// What the owner reads after "Continue with Apple". A recovered account says so.
    nonisolated static func linkNotice(_ r: AppleLinkResponse) -> String {
        r.recovered ? "Welcome back. Your account is here again." : "Saved \u{2713} Your account is safe with your Apple account."
    }

    /// "To save your details, continue with Apple": links the Apple account to this device account.
    /// If the Apple account had an earlier account, the server sends that account's token and the app switches to it.
    func linkApple(identityToken: String, nonce: String) async -> String? {
        do {
            let r = try await APIClient.shared().linkApple(identityToken: identityToken, nonce: nonce)
            if r.recovered {
                guard let token = r.device_token, save(token: token, server: SharedStore.serverURL) else { return "Could not save your account on this phone. Try again." }
            }
            SharedStore.appleLinked = true
            appleLinked = true
            notice = Self.linkNotice(r)
            return nil
        } catch APIError.http(409, _) {
            return "This account is already saved with another Apple account."
        } catch is APIError {
            return "That did not work. Try again."
        } catch {
            return "Cannot reach \(AppConfig.displayName). Check your connection and try again."
        }
    }

    #if DEBUG
    /// Developer path, Debug builds only: pair with a device token from `npm run device`.
    @discardableResult
    func pair(token: String, server: String) async -> Bool {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let server = server.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        do {
            try await APIClient(baseURL: server, token: token).me()
        } catch {
            self.error = "Pairing failed: \(error.localizedDescription)"
            return false
        }
        return save(token: token, server: server)
    }
    #endif

    /// Writes the token to the shared Keychain and reads it back. A failed write shows an error; it never passes silently.
    private func save(token: String, server: String) -> Bool {
        SharedStore.serverURL = server
        let status = SharedStore.setDeviceToken(token)
        guard status == errSecSuccess, SharedStore.deviceToken == token else {
            error = "Could not save your account on this phone (Keychain \(status)). Try again."
            return false
        }
        serverURL = server
        error = nil
        SharedStore.appleLinked = false
        appleLinked = false
        account += 1
        paired = true
        return true
    }

    func finishOnboarding() { onboarding = false }

    func unpair() {
        SharedStore.setDeviceToken(nil)
        SharedStore.appleLinked = false
        appleLinked = false
        notice = nil
        error = nil
        onboarding = true
        paired = false
    }

    /// Dev only: `xcrun simctl openurl <sim> "pip-dev://pair?token=...&server=..."`. It goes straight to Home.
    /// Release builds ignore it, so no web page can pair the app to another server.
    func handle(url: URL) {
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
        // Back from Settings: onboarding and Home see the new keyboard state at once.
        .onChange(of: scenePhase) { _, phase in if phase == .active { KeyboardSetup.shared.refresh() } }
    }
}
