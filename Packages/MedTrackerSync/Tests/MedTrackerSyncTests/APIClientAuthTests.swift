import Foundation
@testable import MedTrackerSync
import Testing

private func client(_ t: MockTransport) -> APIClient {
    APIClient(config: SyncConfig(baseURL: URL(string: "https://x.test/api/v1")!), transport: t)
}

@Test func loginReturnsSession() async throws {
    let t = MockTransport(); t.enqueue(status: 200, json: Fixtures.loginSession)
    let outcome = try await client(t).login(email: "a@b.com", password: "pw")
    guard case let .session(token, user) = outcome else { Issue.record("expected session"); return }
    #expect(token == "sess_abc"); #expect(user.id == "u1")
    // request shape
    #expect(t.requests.last?.url?.absoluteString == "https://x.test/api/v1/auth/login")
    #expect(t.requests.last?.httpMethod == "POST")
    #expect(t.lastBodyJSON?["email"] as? String == "a@b.com")
}

@Test func loginReturnsTotpChallenge() async throws {
    let t = MockTransport(); t.enqueue(status: 200, json: Fixtures.loginTotp)
    let outcome = try await client(t).login(email: "a@b.com", password: "pw")
    #expect(outcome == .totpChallenge(preAuthToken: "pre_xyz"))
}

@Test func loginBadCredentialsThrowsUnauthorized() async throws {
    let t = MockTransport(); t.enqueue(status: 401, json: #"{"message":"Invalid email or password"}"#)
    await #expect(throws: APIError.unauthorized) {
        _ = try await client(t).login(email: "a@b.com", password: "bad")
    }
}

@Test func loginRateLimited() async throws {
    let t = MockTransport()
    t.enqueue(
        status: 429, json: #"{"error":"rate_limited","retryAfterSeconds":30}"#,
        headers: ["Retry-After": "30"]
    )
    await #expect(throws: APIError.rateLimited(retryAfter: 30)) {
        _ = try await client(t).login(email: "a@b.com", password: "pw")
    }
}

@Test func appleConflictThrows() async throws {
    let t = MockTransport(); t.enqueue(status: 409, json: #"{"message":"email_conflict"}"#)
    await #expect(throws: APIError.emailConflict) {
        _ = try await client(t).signInWithApple(identityToken: "tok", fullName: nil)
    }
}
