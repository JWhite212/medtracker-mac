import Foundation
import GRDB
import MedTrackerData
@testable import MedTrackerSync
import Testing

private func makeDrainer(
    _ db: DatabaseQueue, _ t: MockTransport, maxCommandsPerRequest: Int = 200
) -> (OutboxDrainer, OutboxStore) {
    let api = APIClient(config: SyncConfig(baseURL: URL(string: "https://x.test/api/v1")!), transport: t)
    let outbox = OutboxStore(dbWriter: db)
    return (
        OutboxDrainer(
            apiClient: api, dbWriter: db, outbox: outbox, maxCommandsPerRequest: maxCommandsPerRequest
        ), outbox
    )
}

// The beta toolchain's overload resolution prefers GRDB's `async` `write`/`read`
// over the synchronous ones when the call is lexically inside an `async` test
// function, even though the closures we pass are synchronous. These non-async
// wrappers keep the call site outside the `async` context so the sync
// overloads resolve, matching every other test in this suite.
private func write(_ db: DatabaseQueue, _ work: @escaping (Database) throws -> Void) throws {
    try db.write(work)
}

private func read<T>(_ db: DatabaseQueue, _ work: @escaping (Database) throws -> T) throws -> T {
    try db.read(work)
}

@Test func drainCreateDoseReconcilesServerId() async throws {
    let db = try MedTrackerDatabase.open()
    let t = MockTransport()
    let (drainer, outbox) = makeDrainer(db, t)
    try write(db) { d in
        try Medication(id: "m1", userId: "u1", name: "M", dosageAmount: "1", dosageUnit: "mg",
                       form: "tablet", category: "otc", colour: "#000000", startedAt: 0, createdAt: 0,
                       updatedAt: 0).insert(d)
        try DoseLog(id: "localDose", userId: "u1", medicationId: "m1", takenAt: 0, loggedAt: 0,
                    updatedAt: 0).insert(d)
    }
    let e = try outbox.enqueue(type: "log_dose", payload: .object(["medicationId": .string("m1")]),
                               localEntityId: "localDose", localEntityKind: .doseLog)
    t.enqueue(status: 200,
              json: #"{"results":[{"id":"\#(e.idempotencyKey)","ok":true,"result":{"id":"srvDose"}}]}"#)
    let res = try await drainer.drain(token: "tok")
    #expect(res == DrainResult(sent: 1, failed: 0, inProgress: 0))
    try read(db) { d in
        try #expect(DoseLog.fetchOne(d, key: "srvDose") != nil)
        try #expect(OutboxEntry.fetchOne(d, key: e.id)?.status == "sent")
    }
}

@Test func drainHandlesErrorAndInProgressIndependently() async throws {
    let db = try MedTrackerDatabase.open()
    let t = MockTransport()
    let (drainer, outbox) = makeDrainer(db, t)
    let a = try outbox.enqueue(type: "refill", payload: .object([:]))
    let b = try outbox.enqueue(type: "refill", payload: .object([:]))
    t.enqueue(status: 200, json: """
    {"results":[{"id":"\(a.idempotencyKey)","ok":false,"error":"not found"},
                {"id":"\(b.idempotencyKey)","ok":false,"error":"in_progress"}]}
    """)
    let res = try await drainer.drain(token: "tok")
    #expect(res == DrainResult(sent: 0, failed: 1, inProgress: 1))
    try read(db) { d in
        try #expect(OutboxEntry.fetchOne(d, key: a.id)?.status == "failed")
        try #expect(OutboxEntry.fetchOne(d, key: b.id)?.status == "pending") // left for next sync
    }
}

@Test func drainAppliesEarlierChunkBeforeLaterChunkAborts() async throws {
    let db = try MedTrackerDatabase.open()
    let t = MockTransport()
    let (drainer, outbox) = makeDrainer(db, t, maxCommandsPerRequest: 1)
    let a = try outbox.enqueue(type: "refill", payload: .object([:]))
    let b = try outbox.enqueue(type: "refill", payload: .object([:]))

    // Chunk 1 (entry a) succeeds...
    t.enqueue(status: 200, json: #"{"results":[{"id":"\#(a.idempotencyKey)","ok":true,"result":null}]}"#)
    // ...but chunk 2 (entry b) fails at the transport level, aborting the drain.
    t.enqueue(status: 500, json: #"{"message":"boom"}"#)

    await #expect(throws: APIError.server(status: 500)) {
        _ = try await drainer.drain(token: "tok")
    }

    try read(db) { d in
        try #expect(OutboxEntry.fetchOne(d, key: a.id)?.status == "sent") // durable despite later abort
        try #expect(OutboxEntry.fetchOne(d, key: b.id)?.status == "pending") // never attempted
    }
}
