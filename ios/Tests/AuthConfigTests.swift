import XCTest
@testable import Pip

/// A server that answers GET /v1/auth/config with `code` and `body`.
final class ConfigStub: URLProtocol {
    nonisolated(unsafe) static var code = 200
    nonisolated(unsafe) static var body = ""
    nonisolated(unsafe) static var paths: [String] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.paths.append(request.url?.path ?? "")
        let resp = HTTPURLResponse(url: request.url!, statusCode: Self.code, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// The sign-in screen offers email only when the server says it can send the codes.
final class AuthConfigTests: XCTestCase {
    private var stubbed: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ConfigStub.self]
        return URLSession(configuration: config)
    }

    private func enabled(_ code: Int, _ body: String) async -> Bool {
        ConfigStub.code = code
        ConfigStub.body = body
        return await APIClient.emailEnabled(baseURL: "http://127.0.0.1:9", session: stubbed)
    }

    func testEmailFollowsTheServerFlag() async {
        ConfigStub.paths = []
        let on = await enabled(200, #"{"email_enabled":true}"#)
        XCTAssertTrue(on)
        XCTAssertEqual(ConfigStub.paths, ["/v1/auth/config"])
        let off = await enabled(200, #"{"email_enabled":false}"#)
        XCTAssertFalse(off)
    }

    func testAnOlderServerOrABadReplyHidesEmail() async {
        let missing = await enabled(404, #"{"error":"not found"}"#)
        XCTAssertFalse(missing, "a server without the config route has no email")
        let broken = await enabled(500, #"{"email_enabled":true}"#)
        XCTAssertFalse(broken)
        let garbled = await enabled(200, "not json")
        XCTAssertFalse(garbled)
    }

    func testAccountOffersAddEmailOnlyWhenTheServerCanSendTheCode() {
        let device = AccountInfo(email: nil, email_verified: false, apple: false, password: false, anonymous: true)
        let withPassword = AccountInfo(email: "a@example.com", email_verified: true, apple: false, password: true, anonymous: false)
        XCTAssertTrue(AccountView.offersEmail(device, emailEnabled: true))
        XCTAssertFalse(AccountView.offersEmail(device, emailEnabled: false), "no Resend key: no add-email button")
        XCTAssertFalse(AccountView.offersEmail(withPassword, emailEnabled: true))
        XCTAssertFalse(AccountView.offersEmail(nil, emailEnabled: true))
    }
}
