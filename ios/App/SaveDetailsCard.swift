import AuthenticationServices
import CryptoKit
import SwiftUI

/// "To save your details, continue with Apple". The app works without it: the account lives on this phone until the owner links it.
/// The button is Apple's own Sign in with Apple button, unstyled.
struct SaveDetailsCard: View {
    var title: String? = nil
    @EnvironmentObject var session: Session
    @Environment(\.colorScheme) private var colorScheme
    @State private var nonce = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                    if let title { Text(title).font(Theme.Font.cardTitle).foregroundStyle(Theme.Color.text1) }
                    Text("To save your details, continue with Apple.").font(title == nil ? Theme.Font.body : Theme.Font.label)
                        .foregroundStyle(title == nil ? Theme.Color.text1 : Theme.Color.text2).fixedSize(horizontal: false, vertical: true)
                    Text("If you delete the app or change phones, you get the same account back.").font(Theme.Font.label)
                        .foregroundStyle(Theme.Color.text2).fixedSize(horizontal: false, vertical: true)
                }
                SignInWithAppleButton(.continue) { request in
                    error = nil
                    nonce = Self.randomNonce()
                    request.requestedScopes = []
                    request.nonce = Self.sha256(nonce)
                } onCompletion: { result in
                    Task { await finished(result) }
                }
                .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                .frame(height: Theme.Metric.secondaryButton)
                .opacity(busy ? 0.5 : 1)
                .disabled(busy)
                .accessibilityIdentifier("save.apple")
                if let error {
                    Text(error).font(Theme.Font.label).foregroundStyle(Theme.Color.warning).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("save.error")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("save.card")
    }

    private func finished(_ result: Result<ASAuthorization, Error>) async {
        switch result {
        case .failure(let e):
            // A cancel is the owner's choice, so it shows no error.
            if (e as? ASAuthorizationError)?.code != .canceled { error = "Apple sign-in did not finish. Try again." }
        case .success(let auth):
            guard let cred = auth.credential as? ASAuthorizationAppleIDCredential,
                  let token = cred.identityToken.flatMap({ String(data: $0, encoding: .utf8) }) else {
                error = "Apple sign-in did not finish. Try again."
                return
            }
            busy = true
            error = await session.linkApple(identityToken: token, nonce: nonce)
            busy = false
        }
    }

    private static func randomNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private static func sha256(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
