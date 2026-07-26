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
