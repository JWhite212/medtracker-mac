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

    /// Inserts a new `"pending"` outbox row for `type`/`payload` and returns it.
    /// `payload` is JSON-encoded to a string via `JSONEncoder`; `id` and
    /// `idempotencyKey` are independently generated `createId()` values (the
    /// idempotency key is what the server dedupes retries on, so it must stay
    /// stable across `markFailed` retries of the same row).
    @discardableResult
    public func enqueue(
        type: String,
        payload: JSONValue,
        localEntityId: String? = nil,
        localEntityKind: EntityKind? = nil
    ) throws -> OutboxEntry {
        let payloadData = try JSONEncoder().encode(payload)
        // JSONEncoder always emits valid UTF-8, so the failable initializer
        // SwiftLint prefers here can never return nil.
        let payloadJSON = String(data: payloadData, encoding: .utf8)!

        let entry = OutboxEntry(
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

        return try dbWriter.write { db in
            try entry.insert(db)
            return entry
        }
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
