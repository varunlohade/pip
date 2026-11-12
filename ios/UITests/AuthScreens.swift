import XCTest

/// The sign-in and account screens against `npm run fake` (FAKE_URL). No model call and no real email: the fake's /_mail
/// shows the stub mail. Screens go to SHOT_DIR when it is set.
final class AuthScreens: XCTestCase {
    private let env = ProcessInfo.processInfo.environment
    private var fake: String { env["FAKE_URL"] ?? "http://127.0.0.1:8799" }
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-intro_seen", "YES", "-serverURL", fake]
        app.launch()
    }

    private func el(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@", id)).firstMatch
    }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
        if let dir = env["SHOT_DIR"] {
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
        }
    }

    /// From wherever the app opens, to the sign-in choices: log out first if signed in, then pass the setup steps.
    private func toSignIn() {
        if el("nav.account").waitForExistence(timeout: 3) { logOut() }
        if el("hero.add").waitForExistence(timeout: 2) { el("hero.add").tap() }
        for _ in 0..<8 {
            if el("signin.apple").waitForExistence(timeout: 2) { return }
            for id in ["onboarding.later", "onboarding.default.later", "onboarding.default.next", "onboarding.calendar.later"] where el(id).exists {
                el(id).tap()
                break
            }
        }
        XCTAssertTrue(el("signin.apple").exists, "no sign-in screen: \(app.debugDescription.suffix(1500))")
    }

    /// After a logout the app opens straight at the sign-in step: not the intro, not a setup step.
    private func signInShows() -> Bool {
        el("signin.apple").waitForExistence(timeout: 8) && !el("hero.add").exists
    }

    private func logOut() {
        el("nav.account").tap()
        XCTAssertTrue(el("account.logout").waitForExistence(timeout: 5))
        el("account.logout").tap()
        app.alerts["Log out?"].buttons["Log out"].firstMatch.tap()
        XCTAssertTrue(signInShows(), "sign-in after logout: \(app.debugDescription.suffix(1500))")
    }

    /// iOS may offer to save the password when a password field goes away. The test says Not Now.
    private func dismissSystemPrompts() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for target in [app!, springboard] {
            let notNow = target.buttons["Not Now"]
            if notNow.waitForExistence(timeout: 1) { notNow.tap() }
        }
    }

    private func type(_ id: String, _ text: String) {
        let f = el(id)
        XCTAssertTrue(f.waitForExistence(timeout: 3), id)
        if !f.isHittable { dismissSystemPrompts() }
        f.tap()
        if let old = f.value as? String, !old.isEmpty, f.placeholderValue != old {
            f.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count))
        }
        // A secure field drops keys typed in one burst, so it gets one key at a time.
        if f.elementType == .secureTextField {
            for ch in text { f.typeText(String(ch)) }
        } else {
            f.typeText(text)
        }
    }

    private func submit(expectError line: String) {
        el("email.submit").tap()
        let err = el("email.error")
        XCTAssertTrue(err.waitForExistence(timeout: 8), "no error line for: \(line)")
        XCTAssertEqual(err.label, line)
    }

    /// The last stub code the fake server "mailed" to this address.
    private func code(for email: String) throws -> String {
        let data = try Data(contentsOf: URL(string: fake + "/_mail")!)
        struct Out: Decodable { struct M: Decodable { let to: String; let kind: String; let code: String? }; let mails: [M] }
        return try XCTUnwrap(JSONDecoder().decode(Out.self, from: data).mails.last { $0.to == email && $0.code != nil }?.code)
    }

    func test1SignInScreenValidationAndErrors() {
        toSignIn()
        XCTAssertTrue(el("signin.apple").isHittable, "Sign in with Apple is on screen")
        XCTAssertTrue(el("signin.email").exists)
        XCTAssertTrue(el("onboarding.start").exists, "Skip for now")
        shot("auth-1-sign-in")

        el("signin.email").tap()
        XCTAssertTrue(el("email.title").waitForExistence(timeout: 3))
        submit(expectError: "Type your email.")
        type("email.field", "not-an-email")
        submit(expectError: "That email does not look right.")
        shot("auth-2-email-invalid")

        el("email.toSignUp").tap()
        XCTAssertEqual(el("email.title").label, "Make an account")
        type("email.field", "new.person@example.com")
        type("password.field", "short")
        submit(expectError: "Use at least 10 characters.")
        shot("auth-3-password-short")

        el("email.toSignIn").tap()
        type("email.field", "nobody@example.com")
        type("password.field", "this is not the password")
        submit(expectError: "Wrong email or password")
        shot("auth-4-wrong-password")
        el("email.cancel").tap()
        XCTAssertTrue(el("signin.apple").waitForExistence(timeout: 3))
    }

    func test2SignUpThenAccountConfirmsThenLogOut() throws {
        toSignIn()
        el("signin.email").tap()
        el("email.toSignUp").tap()
        let email = "ui.\(Int(Date().timeIntervalSince1970))@example.com"
        type("email.field", email)
        type("password.field", "a long enough sentence")
        el("email.submit").tap()
        XCTAssertTrue(el("code.field").waitForExistence(timeout: 8), "no code step: \(el("email.error").exists ? el("email.error").label : String(app.debugDescription.suffix(2500)))")
        shot("auth-5-check-email")
        type("code.field", try code(for: email))
        el("email.submit").tap()
        XCTAssertTrue(el("nav.account").waitForExistence(timeout: 15), "no Home after sign-up")

        el("nav.account").tap()
        XCTAssertTrue(el("account.who").waitForExistence(timeout: 5))
        let who = el("account.who")
        expectation(for: NSPredicate(format: "label == %@", email), evaluatedWith: who)
        waitForExpectations(timeout: 8)
        shot("auth-6-account")

        el("account.logout").tap()
        XCTAssertTrue(app.alerts["Log out?"].waitForExistence(timeout: 3))
        shot("auth-7-logout-confirm")
        app.alerts.buttons["Cancel"].tap()
        XCTAssertTrue(el("account.logout").exists, "Cancel keeps you signed in")

        el("account.logoutAll").tap()
        XCTAssertTrue(app.alerts["Log out everywhere?"].waitForExistence(timeout: 3))
        app.alerts.buttons["Cancel"].tap()

        el("account.delete").tap()
        XCTAssertTrue(app.alerts["Delete your account?"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.alerts.secureTextFields.firstMatch.exists, "an account with a password confirms with it")
        shot("auth-8-delete-confirm")
        app.alerts.buttons["Cancel"].tap()

        el("account.logout").tap()
        app.alerts["Log out?"].buttons["Log out"].firstMatch.tap()
        XCTAssertTrue(signInShows(), "sign-in after logout: \(app.debugDescription.suffix(1500))")
        XCTAssertFalse(el("nav.account").exists)
        shot("auth-9-after-logout")
    }
}
