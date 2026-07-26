import Foundation
import GRDB
import MedTrackerData
@testable import MedTrackerSync
import MedTrackerTestSupport
import Testing

@Test func fullResyncWipesAndReplaces() throws {
    let db = try MedTrackerDatabase.open()
    // stale local rows that must be gone afterwards
    try db.write { d in
        try Medication(id: "stale", userId: "u1", name: "Stale", dosageAmount: "1", dosageUnit: "mg",
                       form: "tablet", category: "otc", colour: "#000000", startedAt: 0, createdAt: 0,
                       updatedAt: 0).insert(d)
        // a local-only outbox row that must SURVIVE
        try OutboxEntry(id: "keepme", commandType: "log_dose", payload: "{}",
                        idempotencyKey: "k", createdAt: 0).insert(d)
    }
    var r = try JSONDecoder().decode(SyncResponse.self, from: Data(Fixtures.syncDelta.utf8))
    r.fullResync = true
    try SyncApplier(dbWriter: db).apply(r)
    try db.read { d in
        try #expect(Medication.fetchOne(d, key: "stale") == nil) // wiped
        try #expect(Medication.fetchOne(d, key: "m1") != nil) // replaced with server row
        try #expect(OutboxEntry.fetchOne(d, key: "keepme") != nil) // local-only preserved
    }
}

@Test func applyIsAtomicOnFailure() throws {
    let db = try MedTrackerDatabase.open()
    // A dose whose medication is absent violates the FK -> whole apply must roll back.
    let bad = """
    {"epoch":1,"fullResync":false,"serverTime":"2026-07-26T10:00:00.000Z",
    "cursor":"2026-07-26T10:00:00.000Z","medications":[],
    "doseLogs":[{"id":"dx","userId":"u1","medicationId":"ghost","quantity":1,
    "takenAt":"2026-07-26T08:00:00.000Z","loggedAt":"2026-07-26T08:00:00.000Z","notes":null,
    "sideEffects":null,"status":"taken","updatedAt":"2026-07-26T08:00:00.000Z"}],
    "inventoryEvents":[],"auditLogs":[],"tombstones":[],"preferences":null,"profile":null}
    """
    let r = try JSONDecoder().decode(SyncResponse.self, from: Data(bad.utf8))
    #expect(throws: (any Error).self) { try SyncApplier(dbWriter: db).apply(r) }
    try db.read { d in try #expect(DoseLog.fetchOne(d, key: "dx") == nil) } // nothing committed
}
