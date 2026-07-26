import Foundation
import GRDB
import MedTrackerData
@testable import MedTrackerSync
import Testing

private func engine(_ db: DatabaseQueue, _ t: MockTransport, _ ts: TokenStore) -> SyncEngine {
    SyncEngine(config: SyncConfig(baseURL: URL(string: "https://x.test/api/v1")!),
               dbWriter: db, tokenStore: ts, transport: t)
}

// The beta toolchain's overload resolution prefers GRDB's `async` `read` over the synchronous
// one when the call is lexically inside an `async` test function, even though the closure we
// pass is synchronous. This non-async wrapper keeps the call site outside the `async` context so
// the sync overload resolves (see the identical wrapper in OutboxDrainerTests.swift).
private func read<T>(_ db: DatabaseQueue, _ work: @escaping (Database) throws -> T) throws -> T {
    try db.read(work)
}

@Test func loginPersistsSession() async throws {
    let db = try MedTrackerDatabase.open(); let t = MockTransport(); let ts = InMemoryTokenStore()
    t.enqueue(status: 200, json: Fixtures.loginSession)
    let outcome = try await engine(db, t, ts).login(email: "a@b.com", password: "pw")
    guard case .session = outcome else { Issue.record("expected session"); return }
    #expect(try ts.load() == StoredSession(token: "sess_abc", userId: "u1"))
}

@Test func syncWithoutSessionThrowsUnauthorized() async throws {
    let db = try MedTrackerDatabase.open(); let t = MockTransport(); let ts = InMemoryTokenStore()
    await #expect(throws: APIError.unauthorized) { _ = try await engine(db, t, ts).sync() }
}

@Test func syncDrainsPullsAppliesAndPersistsCursor() async throws {
    let db = try MedTrackerDatabase.open(); let t = MockTransport(); let ts = InMemoryTokenStore()
    try ts.save(StoredSession(token: "tok", userId: "u1"))
    // no pending outbox -> drain makes NO /commands call; first HTTP is the /sync GET
    t.enqueue(status: 200, json: Fixtures.syncDelta)
    let out = try await engine(db, t, ts).sync()
    #expect(out.fullResync == false)
    #expect(out.pulledMedications == 1)
    #expect(out.pushed == DrainResult(sent: 0, failed: 0, inProgress: 0))
    try read(db) { d in try #expect(Medication.fetchCount(d) == 1) }
    #expect(try SyncStateStore(dbWriter: db).loadCursor() == "2026-07-26T10:00:00.000Z")
    #expect(try SyncStateStore(dbWriter: db).loadEpoch() == 2)
}

@Test func secondSyncSendsStoredCursorAndEpoch() async throws {
    let db = try MedTrackerDatabase.open(); let t = MockTransport(); let ts = InMemoryTokenStore()
    try ts.save(StoredSession(token: "tok", userId: "u1"))
    try SyncStateStore(dbWriter: db).saveCursor("2026-07-26T09:00:00.000Z")
    try SyncStateStore(dbWriter: db).saveEpoch(2)
    t.enqueue(status: 200, json: Fixtures.syncDelta)
    _ = try await engine(db, t, ts).sync()
    let comps = URLComponents(url: t.requests.last!.url!, resolvingAgainstBaseURL: false)!
    #expect(comps.queryItems?.first { $0.name == "since" }?.value == "2026-07-26T09:00:00.000Z")
    #expect(comps.queryItems?.first { $0.name == "epoch" }?.value == "2")
}

@Test func engineEnqueuePassthroughJoinsCallerTransaction() throws {
    let db = try MedTrackerDatabase.open()
    let engine = SyncEngine(config: .production, dbWriter: db, tokenStore: InMemoryTokenStore())
    struct Boom: Error {}

    #expect(throws: Boom.self) {
        try db.write { d in
            _ = try engine.enqueue(d, type: "refill", payload: .object([:]))
            throw Boom()
        }
    }
    try #expect(db.read { try OutboxEntry.fetchCount($0) } == 0)
}
