import XCTest
@testable import Pip

final class ShortcutsProblemTests: XCTestCase {
    func testTooShort() {
        XCTAssertEqual(Shortcuts.problem(";", taken: []), "Use 2 characters or more.")
    }

    func testTooLong() {
        XCTAssertEqual(Shortcuts.problem(String(repeating: "a", count: 21), taken: []), "Use 20 characters or fewer.")
    }

    func testLimitsAreInclusive() {
        XCTAssertNil(Shortcuts.problem(";p", taken: []))
        XCTAssertNil(Shortcuts.problem(String(repeating: "a", count: 20), taken: []))
    }

    func testTaken() {
        XCTAssertEqual(Shortcuts.problem(";omw", taken: [";omw", ";fix"]), "Another shortcut uses ;omw.")
    }

    func testFree() {
        XCTAssertNil(Shortcuts.problem(";addr", taken: [";omw", ";fix"]))
    }
}

final class PlainLineTests: XCTestCase {
    func testServerRefusalUsesItsOwnWords() {
        XCTAssertEqual(plainLine(APIError.http(400, #"{"error":"writing help runs only from an explicit user tap"}"#)),
                       "Writing help runs only from an explicit user tap")
        XCTAssertEqual(plainLine(APIError.http(0, "")), "Something went wrong. Try again.")
        XCTAssertEqual(plainLine(URLError(.notConnectedToInternet)), "No connection. Try again.")
        XCTAssertEqual(plainLine(URLError(.timedOut)), "Took too long. Try again.")
    }

    func testNoStatusCodeReachesTheBar() {
        for code in [500, 502, 503] {
            let line = plainLine(APIError.http(code, #"{"error":"internal error"}"#))
            XCTAssertEqual(line, "Something went wrong. Try again.")
            XCTAssertFalse(line.contains(String(code)))
        }
        XCTAssertEqual(plainLine(APIError.http(401, "")), "Open \(AppConfig.displayName) to sign in")
        XCTAssertEqual(plainLine(APIError.http(429, "")), "Too many tries. Wait a minute.")
    }
}

@MainActor
final class SessionTests: XCTestCase {
    func testAppleLinkAnswerDecodesAndSaysWelcomeBackOnlyForAnEarlierAccount() throws {
        let fresh = try JSONDecoder().decode(AppleLinkResponse.self, from: Data(#"{"linked":true,"recovered":false}"#.utf8))
        XCTAssertEqual(fresh, AppleLinkResponse(linked: true, recovered: false))
        XCTAssertNil(fresh.tokens)
        XCTAssertTrue(Session.linkNotice(fresh).hasPrefix("Saved"))
        let back = try JSONDecoder().decode(AppleLinkResponse.self, from: Data(#"{"linked":true,"recovered":true,"access_token":"pat_a","refresh_token":"prt_r","expires_in":900}"#.utf8))
        XCTAssertEqual(back.tokens, TokenPair(access_token: "pat_a", refresh_token: "prt_r", expires_in: 900))
        XCTAssertTrue(Session.linkNotice(back).hasPrefix("Welcome back"))
    }
}
