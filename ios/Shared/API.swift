import Foundation

/// Any JSON value. Chip payloads go back to the server unchanged.
enum JSONValue: Codable, Hashable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
}

struct Chip: Codable, Hashable, Identifiable {
    let kind: String
    let label: String
    let payload: [String: JSONValue]
    let needs_confirm: Bool
    /// The typed words that caused the chip, such as "lunch with Ana tomorrow". Older servers send none.
    var trigger: String?
    var id: String { kind + label }

    init(kind: String, label: String, payload: [String: JSONValue], needs_confirm: Bool, trigger: String? = nil) {
        self.kind = kind
        self.label = label
        self.payload = payload
        self.needs_confirm = needs_confirm
        self.trigger = trigger
    }
}

struct SuggestResponse: Decodable {
    let chips: [Chip]
    let intent: String
    let timings: [String: Int]?
}

struct WriteResponse: Decodable { let text: String; let changed: Bool? }
/// tone is "upset" (the other person), "blunt" (the owner's draft) or "ok". calm is set unless tone is "ok".
struct ToneResponse: Decodable { let tone: String; let calm: String? }
/// POST /v1/explain: `short` is one line, `body` up to four lines split by newlines.
struct ExplainResponse: Decodable, Equatable { let short: String; let body: String; let visual_ok: Bool }

enum APIError: Error, LocalizedError {
    case notPaired
    case http(Int, String)
    /// A plain line for the owner, made on the phone.
    case message(String)

    var errorDescription: String? { plainLine(self) }
}

/// One short line for the bar. Never a status code or raw JSON.
func plainLine(_ error: Error) -> String {
    let again = "Something went wrong. Try again."
    switch error {
    case APIError.notPaired: return "Open \(AppConfig.displayName) to sign in"
    case APIError.message(let s): return s
    case APIError.http(let code, let body):
        switch code {
        case 401: return "Open \(AppConfig.displayName) to sign in"
        case 429: return "Too many tries. Wait a minute."
        case 400..<500: return serverWords(body) ?? again
        default: return again
        }
    case let e as URLError: return e.code == .timedOut ? "Took too long. Try again." : "No connection. Try again."
    default: return again
    }
}

/// The server's own short `error` text, as a sentence.
func serverWords(_ body: String) -> String? {
    struct Body: Decodable { let error: String }
    guard let e = try? JSONDecoder().decode(Body.self, from: Data(body.utf8)).error, !e.isEmpty, e.count <= 80 else { return nil }
    return e.prefix(1).uppercased() + e.dropFirst()
}

struct APIClient {
    var baseURL: String
    var token: String?
    var session: URLSession = .shared

    static func shared() -> APIClient {
        APIClient(baseURL: SharedStore.serverURL, token: TokenStore.access)
    }

    /// `tap`: the call starts from the owner's tap. The server refuses writing help without this header.
    func request(_ method: String, _ path: String, body: Encodable? = nil, tap: Bool = false) throws -> URLRequest {
        guard let token else { throw APIError.notPaired }
        guard let url = URL(string: baseURL + path) else { throw APIError.message("Server address is wrong") }
        var r = URLRequest(url: url, timeoutInterval: 20)
        r.httpMethod = method
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let enc = JSONEncoder()
            enc.outputFormatting = .sortedKeys
            r.httpBody = try enc.encode(body)
        }
        if tap { r.setValue("tap", forHTTPHeaderField: "X-User-Action") }
        return r
    }

    func send<T: Decodable>(_ r: URLRequest, as: T.Type) async throws -> T {
        try JSONDecoder().decode(T.self, from: await data(r))
    }

    /// Posted when the server refuses this phone's session on a route outside /v1/auth/. userInfo["epoch"] is the account epoch
    /// the call started under, so a late answer from before a logout or a new sign-in does nothing.
    static let tokenRejected = Notification.Name("APIClient.tokenRejected")

    /// One call. An expired access token gets one refresh (shared with the keyboard through the Keychain) and one retry.
    /// A 401 that survives the refresh means the session is dead. A 401 under /v1/auth/ (a wrong password, a refused Apple
    /// token) does not end the session.
    private func data(_ r: URLRequest) async throws -> Data {
        let epoch = SharedStore.accountEpoch
        let rejected = {
            guard r.url?.path.contains("/v1/auth/") == false else { return }
            NotificationCenter.default.post(name: Self.tokenRejected, object: nil, userInfo: epoch.map { ["epoch": $0] } ?? [:])
        }
        var (data, resp) = try await session.data(for: r)
        var code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401, Keychain.get(.refreshToken) != nil {
            let fresh: String
            do {
                fresh = try await TokenRefresher.refreshed(baseURL: baseURL, replacing: token, session: session)
            } catch APIError.notPaired {
                rejected()
                throw APIError.notPaired
            }
            var again = r
            again.setValue("Bearer \(fresh)", forHTTPHeaderField: "Authorization")
            (data, resp) = try await session.data(for: again)
            code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        }
        if code == 401 { rejected() }
        guard (200..<300).contains(code) else { throw APIError.http(code, String(decoding: data, as: UTF8.self)) }
        return data
    }

    func suggest(_ text: String, context: String? = nil) async throws -> SuggestResponse {
        var body = ["text": text]
        if let context { body["context"] = context }
        return try await send(request("POST", "/v1/suggest", body: body), as: SuggestResponse.self)
    }

    // Writing help. Each call starts from a tap, and the server refuses it without the tap header.
    func fix(_ text: String) async throws -> WriteResponse {
        try await send(request("POST", "/v1/write/fix", body: ["text": text], tap: true), as: WriteResponse.self)
    }

    func refine(_ text: String, tone: String) async throws -> WriteResponse {
        try await send(request("POST", "/v1/write/refine", body: ["text": text, "tone": tone], tap: true), as: WriteResponse.self)
    }

    func toneCheck(draft: String, client: String?) async throws -> ToneResponse {
        var body: [String: String] = [:]
        if !draft.isEmpty { body["text"] = draft }
        if let client { body["context"] = client }
        return try await send(request("POST", "/v1/write/tone", body: body, tap: true), as: ToneResponse.self)
    }

    /// Only for text the phone read as an explain request (Explain.detect). Plain chat never calls it.
    func explain(_ text: String) async throws -> ExplainResponse {
        try await send(request("POST", "/v1/explain", body: ["text": text]), as: ExplainResponse.self)
    }

    /// The drawn scene, as JSON the visual page reads. The phone does not decode it; the server already clamped it.
    func explainVisual(_ topic: String) async throws -> Data {
        try await data(request("POST", "/v1/explain/visual", body: ["topic": topic], tap: true))
    }

    /// "Send": uploads the drawing PNG, its JPEG link preview and its title, and returns the short link the keyboard types into
    /// the chat. The link opens a page whose Open Graph tags make the chat show the picture. With no preview, only the PNG goes up.
    func shareDrawing(_ png: Data, preview: Data?, title: String) async throws -> String {
        var r = try request("POST", "/v1/drawings", tap: true)
        if let preview {
            let boundary = "pip-\(UUID().uuidString)"
            r.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            var body = Data()
            func part(_ name: String, file: String? = nil, type: String? = nil, _ data: Data) {
                body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"".utf8))
                if let file, let type { body.append(Data("; filename=\"\(file)\"\r\nContent-Type: \(type)".utf8)) }
                body.append(Data("\r\n\r\n".utf8))
                body.append(data)
                body.append(Data("\r\n".utf8))
            }
            part("image", file: "drawing.png", type: "image/png", png)
            part("preview", file: "preview.jpg", type: "image/jpeg", preview)
            part("title", Data(title.utf8))
            body.append(Data("--\(boundary)--\r\n".utf8))
            r.httpBody = body
        } else {
            r.setValue("image/png", forHTTPHeaderField: "Content-Type")
            r.httpBody = png
        }
        struct Out: Decodable { let url: String }
        return try await send(r, as: Out.self).url
    }

    /// Currency rates for one US dollar. The server reads them at most once an hour; the keyboard keeps the last ones.
    func rates() async throws -> Calc.Rates {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let date = f.date(from: s) ?? ISO8601DateFormatter().date(from: s) else {
                throw DecodingError.dataCorrupted(.init(codingPath: dec.codingPath, debugDescription: "date"))
            }
            return date
        }
        return try d.decode(Calc.Rates.self, from: await data(request("GET", "/v1/rates")))
    }

    /// Checks the token: the Debug pairing sheet calls it before it saves a pasted token.
    func me() async throws {
        struct Me: Decodable { let ok: Bool }
        _ = try await send(request("GET", "/v1/me"), as: Me.self)
    }
}
