import AuthenticationServices
import CryptoKit
import SwiftUI

/// The raw nonce for Sign in with Apple: the app sends its SHA-256 to Apple and the raw value to the server.
/// The server gives a one-time nonce (GET /v1/auth/apple/nonce); when it cannot, the phone makes a random one.
enum AppleNonce {
    static func fetch(baseURL: String) async -> String {
        await APIClient.appleNonce(baseURL: baseURL) ?? random()
    }

    static func random() -> String {
        // SystemRandomNumberGenerator is the system CSPRNG and cannot fail silently.
        var rng = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &rng) }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func sha256(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The identity token from a finished Apple sheet, or a plain line. A cancel is nil with no line: it was the owner's choice.
    static func token(_ result: Result<ASAuthorization, Error>) -> (token: String?, error: String?) {
        switch result {
        case .failure(let e):
            return (nil, (e as? ASAuthorizationError)?.code == .canceled ? nil : "Apple sign-in did not finish. Try again.")
        case .success(let auth):
            guard let cred = auth.credential as? ASAuthorizationAppleIDCredential,
                  let t = cred.identityToken.flatMap({ String(data: $0, encoding: .utf8) }) else { return (nil, "Apple sign-in did not finish. Try again.") }
            return (t, nil)
        }
    }
}

/// Checks made on the phone before any call, so a typo gets an answer at once.
enum EmailRules {
    static let minPassword = 10

    static func emailProblem(_ email: String) -> String? {
        let e = email.trimmingCharacters(in: .whitespaces)
        if e.isEmpty { return "Type your email." }
        return e.range(of: #"^[^@\s]+@[^@\s]+\.[^@\s]+$"#, options: .regularExpression) == nil ? "That email does not look right." : nil
    }

    static func passwordProblem(_ password: String) -> String? {
        password.count < minPassword ? "Use at least \(minPassword) characters." : nil
    }

    static func codeProblem(_ code: String) -> String? {
        code.trimmingCharacters(in: .whitespaces).range(of: #"^\d{6}$"#, options: .regularExpression) == nil ? "Type the 6-digit code from the email." : nil
    }
}

/// The sign-in choices at the end of onboarding: Apple, email, or skip for now. Each one alone is enough.
struct SignInChoices: View {
    @EnvironmentObject var session: Session
    @Environment(\.colorScheme) private var colorScheme
    let busy: Bool
    let skip: () -> Void
    let signedIn: () -> Void
    @State private var nonce = ""
    /// The next nonce, fetched ahead: the Apple button's request runs synchronously.
    @State private var next: String?
    @State private var email = false
    @State private var working = false

    var body: some View {
        VStack(spacing: Theme.Space.xs) {
            SignInWithAppleButton(.signIn) { request in
                session.error = nil
                nonce = next ?? AppleNonce.random()
                next = nil
                request.requestedScopes = []
                request.nonce = AppleNonce.sha256(nonce)
            } onCompletion: { result in
                let (token, line) = AppleNonce.token(result)
                session.error = line
                guard let token else { return }
                Task {
                    working = true
                    session.error = await session.signInWithApple(identityToken: token, nonce: nonce)
                    working = false
                    if session.error == nil { signedIn() }
                }
            }
            .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
            .frame(height: Theme.Metric.secondaryButton + 6)
            .clipShape(Capsule())
            .accessibilityIdentifier("signin.apple")
            Button("Continue with email") { session.error = nil; email = true }
                .buttonStyle(FrostPill())
                .accessibilityIdentifier("signin.email")
            Button(busy ? "One moment\u{2026}" : "Skip for now", action: skip)
                .font(Theme.Font.body).foregroundStyle(Theme.Color.text2)
                .frame(maxWidth: .infinity, minHeight: Theme.Metric.iconButton)
                .accessibilityIdentifier("onboarding.start")
        }
        .disabled(busy || working)
        .task(id: next == nil) { if next == nil { next = await AppleNonce.fetch(baseURL: session.server) } }
        .sheet(isPresented: $email) {
            NavigationStack { EmailAuthView(start: .signIn) { email = false; signedIn() } }
        }
    }
}

/// Email sign-in, sign-up with its code, forgot password, and adding an email to this account.
struct EmailAuthView: View {
    enum Step: Equatable { case signIn, signUp, code, forgot, reset, link, linkCode }

    @EnvironmentObject var session: Session
    @Environment(\.dismiss) private var dismiss
    @State var step: Step
    let done: () -> Void
    @State private var email = ""
    @State private var password = ""
    @State private var code = ""
    @State private var error: String?
    @State private var info: String?
    @State private var busy = false

    init(start: Step, done: @escaping () -> Void) {
        _step = State(initialValue: start)
        self.done = done
    }

    private var title: String {
        switch step {
        case .signIn: "Sign in with email"
        case .signUp: "Make an account"
        case .code, .linkCode: "Check your email"
        case .forgot: "Forgot your password"
        case .reset: "Set a new password"
        case .link: "Add email and password"
        }
    }

    private var button: String {
        switch step {
        case .signIn: "Sign in"
        case .signUp: "Make account"
        case .code, .linkCode: "Confirm"
        case .forgot: "Send code"
        case .reset: "Save password"
        case .link: "Add"
        }
    }

    private var showsEmail: Bool { [.signIn, .signUp, .forgot, .link].contains(step) }
    private var showsPassword: Bool { [.signIn, .signUp, .reset, .link].contains(step) }
    private var showsCode: Bool { [.code, .reset, .linkCode].contains(step) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text(title).font(Theme.Font.title).tracking(Theme.Tracking.title).foregroundStyle(Theme.Color.text1)
                    .accessibilityIdentifier("email.title")
                if let info {
                    Text(info).font(Theme.Font.body).foregroundStyle(Theme.Color.text2).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("email.info")
                }
                if showsEmail {
                    TextField("", text: $email, prompt: Text("Email").foregroundStyle(Theme.Color.text3))
                        .textContentType(.username).keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .modifier(FieldStyle()).accessibilityIdentifier("email.field")
                }
                if showsCode {
                    TextField("", text: $code, prompt: Text("6-digit code").foregroundStyle(Theme.Color.text3))
                        .textContentType(.oneTimeCode).keyboardType(.numberPad)
                        .modifier(FieldStyle()).accessibilityIdentifier("code.field")
                }
                if showsPassword {
                    SecureField("", text: $password, prompt: Text(step == .signIn ? "Password" : "Password, 10 or more characters").foregroundStyle(Theme.Color.text3))
                        // No .newPassword: without an associated domain, iOS's strong-password fill only gets in the way.
                        .textContentType(step == .signIn ? .password : nil)
                        .modifier(FieldStyle()).accessibilityIdentifier("password.field")
                }
                if let error {
                    Text(error).font(Theme.Font.label).foregroundStyle(Theme.Color.warning).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("email.error")
                }
                Button(busy ? "One moment\u{2026}" : button) { Task { await submit() } }
                    .buttonStyle(PrimaryButton())
                    .disabled(busy)
                    .padding(.top, Theme.Space.xs)
                    .accessibilityIdentifier("email.submit")
                links
            }
            .padding(Theme.Metric.cardInset)
        }
        .background(Theme.Color.bg.ignoresSafeArea())
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.accessibilityIdentifier("email.cancel") } }
    }

    @ViewBuilder private var links: some View {
        switch step {
        case .signIn:
            quiet("New here? Make an account", id: "email.toSignUp") { go(.signUp) }
            quiet("Forgot password", id: "email.forgot") { go(.forgot) }
        case .signUp:
            quiet("Have an account? Sign in", id: "email.toSignIn") { go(.signIn) }
        case .code:
            quiet("Send a new code", id: "email.resend") { Task { await resend() } }
        default:
            EmptyView()
        }
    }

    private func quiet(_ title: String, id: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action).font(Theme.Font.body).foregroundStyle(Theme.Color.skyDeep)
            .frame(maxWidth: .infinity, minHeight: Theme.Metric.iconButton).accessibilityIdentifier(id)
    }

    private func go(_ s: Step) {
        error = nil
        info = nil
        step = s
    }

    /// The first problem the phone can see, before any call.
    func localProblem() -> String? {
        if showsEmail, let p = EmailRules.emailProblem(email) { return p }
        if showsCode, let p = EmailRules.codeProblem(code) { return p }
        if showsPassword, step != .signIn, let p = EmailRules.passwordProblem(password) { return p }
        if step == .signIn, password.isEmpty { return "Type your password." }
        return nil
    }

    private func submit() async {
        if let p = localProblem() { error = p; return }
        error = nil
        busy = true
        defer { busy = false }
        let server = session.server
        let mail = email.trimmingCharacters(in: .whitespaces)
        let code = code.trimmingCharacters(in: .whitespaces)
        switch step {
        case .signIn:
            finish(await session.signIn { try await APIClient.emailSignIn(baseURL: server, email: mail, password: password) })
        case .signUp:
            do {
                try await APIClient.emailSignUp(baseURL: server, email: mail, password: password)
                info = "We sent a 6-digit code to \(mail). It works for 15 minutes."
                step = .code
            } catch { self.error = Session.line(error) }
        case .code:
            finish(await session.signIn { try await APIClient.emailVerify(baseURL: server, email: mail, code: code, password: password) })
        case .forgot:
            do {
                try await APIClient.forgotPassword(baseURL: server, email: mail)
                info = "If \(mail) has an account, we sent it a 6-digit code."
                password = ""
                step = .reset
            } catch { self.error = Session.line(error) }
        case .reset:
            finish(await session.signIn { try await APIClient.resetPassword(baseURL: server, email: mail, code: code, password: password) })
        case .link:
            do {
                try await APIClient.shared().linkEmail(email: mail, password: password)
                info = "We sent a 6-digit code to \(mail)."
                step = .linkCode
            } catch { self.error = Session.line(error) }
        case .linkCode:
            do {
                try await APIClient.shared().linkEmailVerify(code: code)
                done()
            } catch { self.error = Session.line(error) }
        }
    }

    private func resend() async {
        let mail = email.trimmingCharacters(in: .whitespaces)
        try? await APIClient.emailSignUp(baseURL: session.server, email: mail, password: password)
        info = "We sent a new code to \(mail)."
    }

    private func finish(_ line: String?) {
        if let line { error = line } else { done() }
    }
}

/// Account: who is signed in, ways to save the account, and Log out, Log out everywhere and Delete account, each with a plain confirm.
struct AccountView: View {
    @EnvironmentObject var session: Session
    @State private var info: AccountInfo?
    @State private var confirm: Session.Leave?
    @State private var password = ""
    @State private var error: String?
    @State private var busy = false
    @State private var addEmail = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Metric.cardGap) {
                Text("Account").font(Theme.Font.title).tracking(Theme.Tracking.title).foregroundStyle(Theme.Color.text1)
                Card {
                    VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                        Text(headline).font(Theme.Font.cardTitle).foregroundStyle(Theme.Color.text1).accessibilityIdentifier("account.who")
                        Text(detail).font(Theme.Font.label).foregroundStyle(Theme.Color.text2).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let info, !info.apple { SaveDetailsCard(title: "Save with Apple") }
                if let info, !info.password {
                    Button("Add email and password") { addEmail = true }.buttonStyle(FrostPill()).accessibilityIdentifier("account.addEmail")
                }
                if let error {
                    Text(error).font(Theme.Font.label).foregroundStyle(Theme.Color.warning).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("account.error")
                }
                VStack(spacing: 0) {
                    row("Log out", id: "account.logout") { confirm = .logout }
                    row("Log out everywhere", id: "account.logoutAll") { confirm = .everywhere }
                    row("Delete account", id: "account.delete", destructive: true) { password = ""; confirm = .delete(password: nil) }
                }
                .ringCard()
                .disabled(busy)
            }
            .padding(Theme.Metric.cardInset)
        }
        .background(Theme.Color.bg.ignoresSafeArea())
        .task(id: session.account) { await load() }
        .sheet(isPresented: $addEmail, onDismiss: { Task { await load() } }) {
            NavigationStack { EmailAuthView(start: .link) { addEmail = false } }
        }
        .alert(alertTitle, isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } })) {
            if case .delete = confirm, info?.password == true {
                SecureField("Password", text: $password).accessibilityIdentifier("account.delete.password")
            }
            Button("Cancel", role: .cancel) { confirm = nil }
            Button(alertButton, role: .destructive) { if let c = confirm { Task { await leave(c) } } }
                .accessibilityIdentifier("account.confirm")
        } message: {
            Text(alertMessage)
        }
    }

    private var headline: String {
        guard let info else { return "Your account" }
        if let email = info.email { return email }
        return info.apple ? "Signed in with Apple" : "Not saved yet"
    }

    private var detail: String {
        guard let info else { return "" }
        if info.anonymous { return "This account lives on this phone only. Save it with Apple or an email to keep it." }
        return [info.apple ? "Apple" : nil, info.password ? "Email and password" : nil].compactMap { $0 }.joined(separator: " and ") + " can sign in."
    }

    private var alertTitle: String {
        switch confirm {
        case .logout: "Log out?"
        case .everywhere: "Log out everywhere?"
        case .delete: "Delete your account?"
        case nil: ""
        }
    }

    private var alertButton: String {
        switch confirm {
        case .logout: "Log out"
        case .everywhere: "Log out everywhere"
        case .delete, nil: "Delete"
        }
    }

    private var alertMessage: String {
        let lost = info?.anonymous == true ? " This account is not saved, so you cannot get it back." : ""
        switch confirm {
        case .logout: return "Pip forgets everything on this phone: words, drawings and notes." + lost
        case .everywhere: return "You are signed out on every phone, and this phone forgets everything." + lost
        case .delete: return "This deletes your account and everything in it, on this phone and on our server. You cannot undo it."
            + (info?.password == true ? " Type your password to confirm." : "")
        case nil: return ""
        }
    }

    private func row(_ title: String, id: String, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).font(Theme.Font.bodyMedium).foregroundStyle(destructive ? Theme.Color.warning : Theme.Color.text1)
                Spacer()
            }
            .padding(.horizontal, Theme.Metric.cardPadding)
            .frame(minHeight: Theme.Metric.secondaryButton + 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    private func load() async {
        info = try? await APIClient.shared().account()
    }

    private func leave(_ how: Session.Leave) async {
        var how = how
        if case .delete = how, info?.password == true { how = .delete(password: password) }
        confirm = nil
        busy = true
        error = await session.leave(how)
        busy = false
    }
}
