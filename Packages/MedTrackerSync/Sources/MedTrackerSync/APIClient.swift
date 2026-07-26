import Foundation

/// Thin `/api/v1` client. Every endpoint is a one-line call into the private `post`/`get`
/// helpers, which share request construction, error mapping (`APIError.from`), and decoding
/// via `send`.
public struct APIClient: Sendable {
    private let config: SyncConfig
    private let transport: HTTPTransport

    public init(config: SyncConfig, transport: HTTPTransport) {
        self.config = config
        self.transport = transport
    }

    /// `POST /auth/login` (contract §2) — either a TOTP challenge or a live session.
    public func login(email: String, password: String) async throws -> LoginOutcome {
        try await post(
            "auth/login", body: LoginBody(email: email, password: password), decode: LoginOutcome.self
        )
    }

    /// `POST /auth/2fa` (contract §2) — completes a TOTP challenge into a live session.
    public func verifyTOTP(preAuthToken: String, code: String) async throws -> (token: String, user: SessionUser) {
        let response = try await post(
            "auth/2fa", body: TOTPBody(preAuthToken: preAuthToken, code: code), decode: SessionResponse.self
        )
        return (response.token, response.user)
    }

    /// `POST /auth/apple` (contract §2) — Sign in with Apple.
    public func signInWithApple(identityToken: String, fullName: String?) async throws
        -> (token: String, user: SessionUser)
    {
        let response = try await post(
            "auth/apple", body: AppleBody(identityToken: identityToken, fullName: fullName),
            decode: SessionResponse.self
        )
        return (response.token, response.user)
    }

    /// `GET /sync` (contract §3) — pulls the delta (or full resync) since `since`, guarded by
    /// `epoch` so the server can force a full resync when the account's sync epoch has bumped.
    public func sync(since: String?, epoch: Int, token: String) async throws -> SyncResponse {
        var queryItems = [URLQueryItem(name: "epoch", value: String(epoch))]
        if let since { queryItems.append(URLQueryItem(name: "since", value: since)) }
        return try await get("sync", queryItems: queryItems, bearer: token, decode: SyncResponse.self)
    }

    /// `POST /commands` (contract §4) — submits the outbox as an idempotent command batch.
    public func runCommands(_ commands: [WireCommand], token: String) async throws -> CommandsResponse {
        try await post(
            "commands", body: CommandEnvelope(commands: commands), bearer: token, decode: CommandsResponse.self
        )
    }

    private func post<Out: Decodable>(
        _ path: String, body: some Encodable, bearer: String? = nil, decode _: Out.Type
    ) async throws -> Out {
        var req = URLRequest(url: config.baseURL.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearer { req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try JSONEncoder().encode(body)
        return try await send(req, decode: Out.self)
    }

    private func get<Out: Decodable>(
        _ path: String, queryItems: [URLQueryItem], bearer: String, decode _: Out.Type
    ) async throws -> Out {
        var components = URLComponents(
            url: config.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false
        )!
        components.queryItems = queryItems
        var req = URLRequest(url: components.url!)
        req.httpMethod = "GET"
        req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        return try await send(req, decode: Out.self)
    }

    private func send<Out: Decodable>(_ req: URLRequest, decode _: Out.Type) async throws -> Out {
        let (data, resp) = try await transport.send(req)
        guard (200 ... 299).contains(resp.statusCode) else {
            throw APIError.from(
                status: resp.statusCode, data: data,
                retryAfterHeader: resp.value(forHTTPHeaderField: "Retry-After")
            )
        }
        do {
            return try JSONDecoder().decode(Out.self, from: data)
        } catch {
            throw APIError.decoding(String(describing: error))
        }
    }
}

private struct LoginBody: Encodable {
    let email: String
    let password: String
}

private struct TOTPBody: Encodable {
    let preAuthToken: String
    let code: String
}

private struct AppleBody: Encodable {
    let identityToken: String
    let fullName: String?
}

/// `{token, user}` — the shared shape of `POST /auth/2fa` and `POST /auth/apple` (contract §2).
private struct SessionResponse: Decodable {
    let token: String
    let user: SessionUser
}
