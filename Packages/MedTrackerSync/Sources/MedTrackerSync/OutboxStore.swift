import Foundation
import GRDB
import MedTrackerCore
import MedTrackerData

/// The local table an `OutboxEntry.localEntityId` refers to, so the
/// Reconciler (Task 13) knows which repository to reconcile against once
/// the server has assigned/confirmed a canonical id.
public enum EntityKind: String, Sendable {
    case medication
    case doseLog = "dose_log"
}

/// Enqueues `/api/v1` commands and tracks their delivery status.
///
/// Every mutating local write (dose log, refill, medication edit, ...) that
/// needs to reach the server enqueues one `OutboxEntry` row here, inside the
/// same local transaction as the write itself. The Drainer (Task 14) later
/// reads `pending()` in FIFO order and POSTs each command, then calls
/// `markSent`/`markFailed` to record the outcome; the Reconciler (Task 13)
/// uses `localEntityId`/`localEntityKind` to fix up local ids once the
/// server responds.
public struct OutboxStore: Sendable {
    private let dbWriter: any DatabaseWriter

    public init(dbWriter: any DatabaseWriter) {
        self.dbWriter = dbWriter
    }

    /// Builds a fresh `"pending"` row for `type`/`payload`. Shared by both `enqueue`
    /// overloads; performs no DB access itself. `id`/`idempotencyKey` are independent
    /// `createId()` values (the idempotency key must stay stable across retries).
    private func makePendingEntry(
        type: String, payload: JSONValue,
        localEntityId: String?, localEntityKind: EntityKind?
    ) throws -> OutboxEntry {
        let payloadData = try JSONEncoder().encode(payload)
        // JSONEncoder always emits valid UTF-8, so this failable init never returns nil.
        let payloadJSON = String(data: payloadData, encoding: .utf8)!
        return OutboxEntry(
            id: createId(),
            commandType: type,
            payload: payloadJSON,
            idempotencyKey: createId(),
            status: "pending",
            attemptCount: 0,
            lastError: nil,
            localEntityId: localEntityId,
            localEntityKind: localEntityKind?.rawValue,
            createdAt: Date().timeIntervalSince1970
        )
    }

    /// Standalone enqueue: opens its own `dbWriter.write` transaction. Unchanged
    /// public behaviour for callers that have no surrounding transaction.
    @discardableResult
    public func enqueue(
        type: String, payload: JSONValue,
        localEntityId: String? = nil, localEntityKind: EntityKind? = nil
    ) throws -> OutboxEntry {
        try dbWriter.write { db in
            try enqueue(db, type: type, payload: payload,
                        localEntityId: localEntityId, localEntityKind: localEntityKind)
        }
    }

    /// Tx-joining enqueue (§4.2): inserts the pending row inside the CALLER's
    /// transaction — no internal `dbWriter.write` — so the optimistic state effect
    /// and this enqueue commit (or roll back) atomically. Used by the Task-10
    /// WriteCoordinator, whose command bodies are one `dbWriter.write { db in … }`.
    @discardableResult
    public func enqueue(
        _ db: Database, type: String, payload: JSONValue,
        localEntityId: String? = nil, localEntityKind: EntityKind? = nil
    ) throws -> OutboxEntry {
        let entry = try makePendingEntry(
            type: type, payload: payload,
            localEntityId: localEntityId, localEntityKind: localEntityKind
        )
        try entry.insert(db)
        return entry
    }

    /// All `"pending"` rows, FIFO by `created_at` with `rowid` as a tiebreak
    /// for rows sharing a timestamp (common when several commands are
    /// enqueued in the same instant).
    public func pending() throws -> [OutboxEntry] {
        try dbWriter.read { db in
            try OutboxEntry
                .filter(Column("status") == "pending")
                .order(Column("created_at"), Column("rowid"))
                .fetchAll(db)
        }
    }

    /// Marks a row delivered.
    public func markSent(_ id: String) throws {
        try dbWriter.write { db in
            guard var entry = try OutboxEntry.fetchOne(db, key: id) else { return }
            entry.status = "sent"
            try entry.update(db)
        }
    }

    /// Marks a delivery attempt failed: increments `attemptCount` and records
    /// `error` as `lastError`, leaving the row `"failed"` for the Drainer to
    /// inspect (retry policy is the Drainer's concern, not the store's).
    public func markFailed(_ id: String, error: String) throws {
        try dbWriter.write { db in
            guard var entry = try OutboxEntry.fetchOne(db, key: id) else { return }
            entry.status = "failed"
            entry.attemptCount += 1
            entry.lastError = error
            try entry.update(db)
        }
    }
}
