import Foundation
import MedTrackerSync
import MedTrackerTestSupport
import Testing
@testable import MedTrackerApp

@MainActor
private func makeModel(_ transport: MockTransport,
                       acknowledged: Bool = true) throws -> (SessionModel, AppEnvironment, UserDefaults) {
    let defaults = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
    defaults.set(acknowledged, forKey: "disclaimerAcknowledged")
    let env = try AppEnvironment.testing(transport: transport)
    return (SessionModel(env: env, defaults: defaults), env, defaults)
}

// MARK: first-run consent gate (§3.1)

@MainActor
@Test func startWithoutAckShowsDisclaimerConsent() async throws {
    let (model, _, _) = try makeModel(MockTransport(), acknowledged: false)
    await model.start()
    #expect(model.phase == .disclaimerConsent)
}

@MainActor
@Test func acknowledgeDisclaimerPersistsFlagAndProceedsToLogin() async throws {
    let (model, _, defaults) = try makeModel(MockTransport(), acknowledged: false)
    await model.start()
    model.acknowledgeDisclaimer()
    #expect(defaults.bool(forKey: "disclaimerAcknowledged") == true)   // persisted
    #expect(model.phase == .unauthenticated(error: nil))               // no token → login
}

@MainActor
@Test func startWithAckAndNoTokenGoesToLogin() async throws {
    let (model, _, _) = try makeModel(MockTransport(), acknowledged: true)
    await model.start()
    #expect(model.phase == .unauthenticated(error: nil))
}

// MARK: login outcome mapping (§3.1)

@MainActor
@Test func signInSessionEntersFirstSync() async throws {
    let t = MockTransport(); t.enqueue(status: 200, json: Fixtures.loginSession)
    let (model, _, _) = try makeModel(t)
    await model.signIn(email: "a@b.com", password: "pw")
    #expect(model.phase == .firstSync(FirstSyncState(pulledMedications: 0, pulledDoseLogs: 0,
                                                     isIndeterminate: true)))
}

@MainActor
@Test func signInTotpEntersChallenge() async throws {
    let t = MockTransport(); t.enqueue(status: 200, json: Fixtures.loginTotp)
    let (model, _, _) = try makeModel(t)
    await model.signIn(email: "a@b.com", password: "pw")
    #expect(model.phase == .totpChallenge(preAuthToken: "pre_xyz", error: nil))
}

@MainActor
@Test func signInBadCredentialsMapsToInvalidCredentials() async throws {
    let t = MockTransport(); t.enqueue(status: 401, json: #"{"message":"Invalid email or password"}"#)
    let (model, _, _) = try makeModel(t)
    await model.signIn(email: "a@b.com", password: "bad")
    #expect(model.phase == .unauthenticated(error: .invalidCredentials))
}

@MainActor
@Test func signInRateLimitedCarriesRetryAfter() async throws {
    let t = MockTransport()
    t.enqueue(status: 429, json: #"{"error":"rate_limited","retryAfterSeconds":30}"#)
    let (model, _, _) = try makeModel(t)
    await model.signIn(email: "a@b.com", password: "pw")
    #expect(model.phase == .unauthenticated(error: .rateLimited(retryAfter: 30)))
}

// MARK: TOTP verify (§3.1) — wrong code retains preAuthToken

@MainActor
@Test func verifyWrongCodeStaysOnChallengeWithError() async throws {
    let t = MockTransport()
    t.enqueue(status: 200, json: Fixtures.loginTotp)                        // reach the challenge
    t.enqueue(status: 401, json: #"{"message":"Incorrect code"}"#)         // verify fails
    let (model, _, _) = try makeModel(t)
    await model.signIn(email: "a@b.com", password: "pw")
    await model.verify(code: "000000")
    #expect(model.phase == .totpChallenge(preAuthToken: "pre_xyz", error: .incorrectCode))
}

@MainActor
@Test func verifyCorrectCodeEntersFirstSync() async throws {
    let t = MockTransport()
    t.enqueue(status: 200, json: Fixtures.loginTotp)      // reach the challenge
    t.enqueue(status: 200, json: Fixtures.loginSession)   // /auth/2fa success — {token, user} shape
    let (model, env, _) = try makeModel(t)
    await model.signIn(email: "a@b.com", password: "pw")
    #expect(model.phase == .totpChallenge(preAuthToken: "pre_xyz", error: nil))
    await model.verify(code: "000000")
    #expect(model.phase == .firstSync(FirstSyncState(pulledMedications: 0, pulledDoseLogs: 0,
                                                     isIndeterminate: true)))
    try #expect(env.tokenStore.load()?.token == "sess_abc")   // session now persisted
}

// MARK: runSync funnel (§3.3)

@MainActor
@Test func runSyncFromFirstSyncBecomesAuthenticated() async throws {
    let t = MockTransport()
    t.enqueue(status: 200, json: Fixtures.loginSession)   // persists a session via SyncEngine
    t.enqueue(status: 200, json: Fixtures.syncDelta)      // the first sync pull
    let (model, _, _) = try makeModel(t)
    await model.signIn(email: "a@b.com", password: "pw")  // → .firstSync
    await model.runSync()
    #expect(model.phase == .authenticated)
}

@MainActor
@Test func runSync401ClearsSessionAndDropsToReLogin() async throws {
    let t = MockTransport()
    t.enqueue(status: 200, json: Fixtures.loginSession)
    t.enqueue(status: 401, json: #"{"message":"Unauthorized"}"#)   // stale session on sync
    let (model, env, _) = try makeModel(t)
    await model.signIn(email: "a@b.com", password: "pw")
    await model.runSync()
    #expect(model.phase == .unauthenticated(error: .sessionExpired))
    try #expect(env.tokenStore.load() == nil)                       // the ONLY place that clears
}

@MainActor
@Test func runSyncTransportFailureKeepsSessionAuthenticated() async throws {
    let t = MockTransport()
    t.enqueue(status: 200, json: Fixtures.loginSession)
    t.enqueue(status: 200, json: Fixtures.syncDelta)   // first sync → authenticated
    let (model, env, _) = try makeModel(t)
    await model.signIn(email: "a@b.com", password: "pw")
    await model.runSync()
    #expect(model.phase == .authenticated)

    t.enqueue(status: 503, json: "upstream down")      // a later refresh fails non-401
    await model.runSync()
    #expect(model.phase == .authenticated)             // dead network never looks like logout
    try #expect(env.tokenStore.load() != nil)          // session untouched
}

// MARK: SIWA (§3.2)

@MainActor
@Test func signInWithAppleEmailConflictMapsToLogin() async throws {
    let t = MockTransport(); t.enqueue(status: 409, json: #"{"message":"email_conflict"}"#)
    let (model, _, _) = try makeModel(t)
    await model.signInWithApple(identityToken: "tok", fullName: nil)
    #expect(model.phase == .unauthenticated(error: .emailConflict))
}

// MARK: reconciliation — sync status indicator (§2.5/§3.4.3)

@MainActor
@Test func runSyncSuccessStampsLastSyncedAtAndClearsError() async throws {
    let t = MockTransport()
    t.enqueue(status: 200, json: Fixtures.loginSession)
    t.enqueue(status: 200, json: Fixtures.syncDelta)
    let (model, _, _) = try makeModel(t)
    await model.signIn(email: "a@b.com", password: "pw")
    #expect(model.lastSyncedAt == nil)
    await model.runSync()
    #expect(model.phase == .authenticated)
    #expect(model.isSyncing == false)
    #expect(model.lastSyncError == nil)
    #expect(model.lastSyncedAt != nil)
}

@MainActor
@Test func runSyncTransportFailureSetsLastSyncErrorNotSessionExpired() async throws {
    let t = MockTransport()
    t.enqueue(status: 200, json: Fixtures.loginSession)
    t.enqueue(status: 200, json: Fixtures.syncDelta)
    let (model, _, _) = try makeModel(t)
    await model.signIn(email: "a@b.com", password: "pw")
    await model.runSync()

    t.enqueue(status: 503, json: "upstream down")
    await model.runSync()
    #expect(model.phase == .authenticated)
    #expect(model.isSyncing == false)
    #expect(model.lastSyncError == .server)
}

@MainActor
@Test func runSync401SetsLastSyncErrorSessionExpired() async throws {
    let t = MockTransport()
    t.enqueue(status: 200, json: Fixtures.loginSession)
    t.enqueue(status: 401, json: #"{"message":"Unauthorized"}"#)
    let (model, _, _) = try makeModel(t)
    await model.signIn(email: "a@b.com", password: "pw")
    await model.runSync()
    #expect(model.phase == .unauthenticated(error: .sessionExpired))
    #expect(model.isSyncing == false)
    #expect(model.lastSyncError == .sessionExpired)
}

// MARK: first full sync (fullResync path)

@MainActor
@Test func runSyncFirstFullResyncBecomesAuthenticated() async throws {
    let t = MockTransport()
    t.enqueue(status: 200, json: Fixtures.loginSession)
    let fullResyncDelta = Fixtures.syncDelta.replacingOccurrences(
        of: "\"fullResync\":false", with: "\"fullResync\":true"
    )
    t.enqueue(status: 200, json: fullResyncDelta)
    let (model, _, _) = try makeModel(t)
    await model.signIn(email: "a@b.com", password: "pw")
    #expect(model.phase == .firstSync(FirstSyncState(pulledMedications: 0, pulledDoseLogs: 0,
                                                     isIndeterminate: true)))
    await model.runSync()
    #expect(model.phase == .authenticated)
}

// MARK: sign out

@MainActor
@Test func signOutClearsSessionAndDropsToLogin() async throws {
    let t = MockTransport()
    t.enqueue(status: 200, json: Fixtures.loginSession)
    t.enqueue(status: 200, json: Fixtures.syncDelta)
    let (model, env, _) = try makeModel(t)
    await model.signIn(email: "a@b.com", password: "pw")
    await model.runSync()
    #expect(model.phase == .authenticated)
    model.signOut()
    #expect(model.phase == .unauthenticated(error: nil))
    try #expect(env.tokenStore.load() == nil)
}
