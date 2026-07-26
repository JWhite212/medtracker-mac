import Foundation
import GRDB
import MedTrackerData
@testable import MedTrackerSync
import Testing

@Test func enqueueWritesPendingRowWithReconciliationFields() throws {
    let db = try MedTrackerDatabase.open()
    let store = OutboxStore(dbWriter: db)
    let e = try store.enqueue(
        type: "log_dose", payload: .object(["medicationId": .string("m1")]),
        localEntityId: "localDose1", localEntityKind: .doseLog
    )
    #expect(e.status == "pending")
    #expect(e.localEntityId == "localDose1")
    #expect(e.localEntityKind == "dose_log")
    #expect(!e.idempotencyKey.isEmpty)
    let pend = try store.pending()
    #expect(pend.map(\.id) == [e.id])
}

@Test func markSentAndFailedTransition() throws {
    let db = try MedTrackerDatabase.open()
    let store = OutboxStore(dbWriter: db)
    let a = try store.enqueue(type: "refill", payload: .object([:]))
    try store.markSent(a.id)
    #expect(try store.pending().isEmpty)
    let b = try store.enqueue(type: "refill", payload: .object([:]))
    try store.markFailed(b.id, error: "boom")
    let row = try db.read { try OutboxEntry.fetchOne($0, key: b.id) }
    #expect(row?.status == "failed")
    #expect(row?.attemptCount == 1)
    #expect(row?.lastError == "boom")
}

@Test func pendingIsFIFO() throws {
    let db = try MedTrackerDatabase.open()
    let store = OutboxStore(dbWriter: db)
    let first = try store.enqueue(type: "a", payload: .object([:]))
    let second = try store.enqueue(type: "b", payload: .object([:]))
    #expect(try store.pending().map(\.id) == [first.id, second.id]) // created_at, then rowid tiebreak
}

/// Forces a real `created_at` collision (three rows share the exact same
/// timestamp) and asserts `pending()` falls back to `rowid` — i.e. insertion
/// order — to break the tie. Ids are chosen so their ascending string sort
/// disagrees with insertion order, so a query that accidentally ordered by
/// `id` instead of `rowid` would produce a different, and therefore failing,
/// result.
@Test func pendingBreaksCreatedAtTieByRowid() throws {
    let db = try MedTrackerDatabase.open()
    let store = OutboxStore(dbWriter: db)
    let collidingCreatedAt = 100.0

    let rows = [
        OutboxEntry(
            id: "z_first", commandType: "a", payload: "{}",
            idempotencyKey: "idem_z_first", createdAt: collidingCreatedAt
        ),
        OutboxEntry(
            id: "m_second", commandType: "b", payload: "{}",
            idempotencyKey: "idem_m_second", createdAt: collidingCreatedAt
        ),
        OutboxEntry(
            id: "a_third", commandType: "c", payload: "{}",
            idempotencyKey: "idem_a_third", createdAt: collidingCreatedAt
        ),
    ]

    try db.write { db in
        for row in rows {
            try row.insert(db)
        }
    }

    #expect(try store.pending().map(\.id) == ["z_first", "m_second", "a_third"])
}

/// Closes a T3 invariant with no committed test: a whole-number `.number` payload field must
/// round-trip through `JSONEncoder` as an integer literal (`2`), not `2.0` — the `/api/v1`
/// server-side JSON decoder is strict about numeric shape for some fields.
@Test func enqueueEncodesWholeNumberPayloadFieldWithoutDecimal() throws {
    let db = try MedTrackerDatabase.open()
    let store = OutboxStore(dbWriter: db)
    let e = try store.enqueue(
        type: "log_dose",
        payload: .object(["quantity": .number(2), "medicationId": .string("m1")])
    )
    let row = try db.read { try OutboxEntry.fetchOne($0, key: e.id) }
    let payload = try #require(row?.payload)
    #expect(payload.contains("\"quantity\":2") || payload.contains("\"quantity\": 2"))
    #expect(!payload.contains("2.0"))
}

/// §4.2 write-path rule: the optimistic STATE effect and the outbox enqueue must
/// commit atomically. Rolling back the caller's block (here: a thrown error inside
/// the same db.write) must leave NEITHER the state row NOR the pending row behind —
/// proving the tx-joining overload takes no internal transaction of its own.
@Test func txJoiningEnqueueRollsBackWithCallerBlock() throws {
    let db = try MedTrackerDatabase.open()
    let store = OutboxStore(dbWriter: db)
    struct Boom: Error {}

    #expect(throws: Boom.self) {
        try db.write { d in
            try Medication(
                id: "m1", userId: "u1", name: "Med", dosageAmount: "50", dosageUnit: "mg",
                form: "tablet", category: "prescription", colour: "#112233",
                startedAt: 0, createdAt: 0, updatedAt: 0
            ).insert(d)
            _ = try store.enqueue(
                d, type: "log_dose", payload: .object(["medicationId": .string("m1")]),
                localEntityId: "localDose1", localEntityKind: .doseLog
            )
            throw Boom()
        }
    }

    try #expect(db.read { try Medication.fetchCount($0) } == 0)
    try #expect(db.read { try OutboxEntry.fetchCount($0) } == 0)
}

/// The mirror case: when the caller's block commits, BOTH rows land, and the
/// returned entry carries the reconciliation fields for the Drainer/Reconciler.
@Test func txJoiningEnqueueCommitsWithCallerBlock() throws {
    let db = try MedTrackerDatabase.open()
    let store = OutboxStore(dbWriter: db)

    let entry = try db.write { d -> OutboxEntry in
        try Medication(
            id: "m1", userId: "u1", name: "Med", dosageAmount: "50", dosageUnit: "mg",
            form: "tablet", category: "prescription", colour: "#112233",
            startedAt: 0, createdAt: 0, updatedAt: 0
        ).insert(d)
        return try store.enqueue(
            d, type: "log_dose", payload: .object(["medicationId": .string("m1")]),
            localEntityId: "localDose1", localEntityKind: .doseLog
        )
    }

    #expect(entry.status == "pending")
    #expect(entry.localEntityId == "localDose1")
    #expect(entry.localEntityKind == "dose_log")
    #expect(!entry.idempotencyKey.isEmpty)
    try #expect(db.read { try Medication.fetchCount($0) } == 1)
    try #expect(db.read { try OutboxEntry.fetchCount($0) } == 1)
}
