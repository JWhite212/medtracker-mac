import Foundation
import GRDB
@testable import MedTrackerApp
import MedTrackerData
import MedTrackerSync
import MedTrackerTestSupport
import Testing

@MainActor
@Test func ingEnvComposesInMemoryDoublesIntoASyncEngine() throws {
    let env = try AppEnvironment.testing(transport: MockTransport())

    // token store starts empty (no session persisted yet)
    try #expect(env.tokenStore.load() == nil)

    // the dbWriter is a usable in-memory GRDB replica with the schema migrated in
    let count = try env.dbWriter.read { db in try Profile.fetchCount(db) }
    #expect(count == 0)

    // round-trips a write through the same connection the SyncEngine was built on
    try env.dbWriter.write { db in
        try Profile(id: 1, userId: "u1", email: "a@b.com", name: "A",
                    timezone: "Europe/London", createdAt: 0, updatedAt: 0).insert(db)
    }
    let after = try env.dbWriter.read { db in try Profile.fetchCount(db) }
    #expect(after == 1)

    // a SyncEngine exists and is the same actor instance held by the environment
    let engine: SyncEngine = env.syncEngine
    #expect(engine === env.syncEngine)
}

@MainActor
@Test func ingEnvAcceptsAnInjectedTokenStore() throws {
    let tok = InMemoryTokenStore()
    try tok.save(StoredSession(token: "t", userId: "u1"))
    let env = try AppEnvironment.testing(transport: MockTransport(), tokenStore: tok)
    try #expect(env.tokenStore.load() == StoredSession(token: "t", userId: "u1"))
}
