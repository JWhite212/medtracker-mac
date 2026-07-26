import Foundation
import GRDB
import MedTrackerData

/// Rewrites a locally-generated id to the server-assigned id once a create
/// command's ack comes back from `/api/v1`, so the local replica converges
/// on the server's canonical identity for the row.
///
/// `reconcile(localId:serverId:kind:in:)` must run **inside an existing
/// write transaction that has `PRAGMA defer_foreign_keys = ON`** for that
/// transaction. The Drainer (Task 14) owns setting that pragma before
/// calling in: rewriting `medication.id` momentarily breaks the
/// `medication_schedule.medication_id` / `dose_log.medication_id` foreign
/// keys until the cascading `UPDATE`s below run later in the same
/// statement sequence, and SQLite only tolerates that with deferred FK
/// enforcement (checked at commit, not per-statement).
public struct Reconciler: Sendable {
    public init() {}

    /// Rewrites the created row's own id (and, for `.medication`, its
    /// children's foreign keys), then remaps `localId → serverId` inside
    /// every still-`"pending"` outbox payload so any queued command that
    /// referenced the local id (e.g. "log a dose against the medication I
    /// just created offline") now targets the server id instead.
    public func reconcile(localId: String, serverId: String, kind: EntityKind, in db: Database) throws {
        switch kind {
        case .doseLog:
            try db.execute(
                sql: "UPDATE dose_log SET id = ? WHERE id = ?",
                arguments: [serverId, localId]
            )
        case .medication:
            try db.execute(
                sql: "UPDATE medication SET id = ? WHERE id = ?",
                arguments: [serverId, localId]
            )
            try db.execute(
                sql: "UPDATE medication_schedule SET medication_id = ? WHERE medication_id = ?",
                arguments: [serverId, localId]
            )
            try db.execute(
                sql: "UPDATE dose_log SET medication_id = ? WHERE medication_id = ?",
                arguments: [serverId, localId]
            )
        }

        try remapPendingOutboxPayloads(localId: localId, serverId: serverId, in: db)
    }

    /// Decodes each still-`"pending"` outbox row's `payload` to a
    /// `JSONValue`, replaces every occurrence of `localId` with `serverId`
    /// throughout it, and re-encodes/writes it back — but only when the
    /// replacement actually changed something, to avoid a needless write.
    private func remapPendingOutboxPayloads(localId: String, serverId: String, in db: Database) throws {
        let pending = try OutboxEntry.filter(Column("status") == "pending").fetchAll(db)
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()

        for entry in pending {
            let original = try decoder.decode(JSONValue.self, from: Data(entry.payload.utf8))
            let remapped = original.replacing(localId, with: serverId)
            guard remapped != original else { continue }

            let payloadData = try encoder.encode(remapped)
            let payloadJSON = String(decoding: payloadData, as: UTF8.self)
            try db.execute(
                sql: "UPDATE outbox SET payload = ? WHERE id = ?",
                arguments: [payloadJSON, entry.id]
            )
        }
    }
}
