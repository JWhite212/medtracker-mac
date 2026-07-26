import Foundation
import GRDB
import MedTrackerData

/// Applies a `GET /sync` response (contract §3) to the local GRDB replica.
///
/// `apply(_:)` runs the whole response in a single `dbWriter.write { db in
/// ... }` transaction and branches on `response.fullResync`:
/// - `false` (this task) — the delta-apply branch: per-row upserts, plus a
///   wholesale replace of each touched medication's `medication_schedule`
///   rows, plus tombstone deletes.
/// - `true` (Task 11) — the full-resync branch: wipes and reloads every
///   synced table from the response. Stubbed here with `fatalError` so any
///   accidental full-resync call surfaces immediately rather than silently
///   no-opping; Task 11 replaces the stub.
public struct SyncApplier: Sendable {
    /// Wire `entityType` → local table name, whitelisted per contract §3.
    /// Unknown entity types are ignored rather than throwing, since the
    /// server may introduce new tombstone kinds the client doesn't sync yet.
    private static let tombstoneTables: [String: String] = [
        "medication": Medication.databaseTableName,
        "dose_log": DoseLog.databaseTableName,
        "medication_schedule": MedicationSchedule.databaseTableName,
        "inventory_event": InventoryEvent.databaseTableName,
    ]

    private let dbWriter: any DatabaseWriter

    public init(dbWriter: any DatabaseWriter) {
        self.dbWriter = dbWriter
    }

    public func apply(_ response: SyncResponse) throws {
        try dbWriter.write { db in
            if response.fullResync {
                try Self.applyFull(db, response)
            } else {
                try Self.applyDelta(db, response)
            }
        }
    }

    /// Task 11 fills this in. Left as a stub (rather than a silent no-op)
    /// so a full-resync response hitting this branch before Task 11 lands
    /// fails loudly instead of dropping data on the floor.
    private static func applyFull(_: Database, _: SyncResponse) throws {
        fatalError("SyncApplier.applyFull is not implemented yet (Task 11)")
    }

    /// The `fullResync == false` branch (contract §3 delta rules).
    /// Medications are upserted (and their schedules wholesale-replaced)
    /// before dose logs / inventory events / audit logs so FKs hold.
    private static func applyDelta(_ db: Database, _ response: SyncResponse) throws {
        for w in response.medications {
            try WireMapping.medication(w).upsert(db)
            try MedicationSchedule.filter(Column("medication_id") == w.id).deleteAll(db)
            for s in w.schedules {
                try WireMapping.schedule(s).insert(db)
            }
        }

        for w in response.doseLogs {
            try WireMapping.doseLog(w).upsert(db)
        }

        for w in response.inventoryEvents {
            try WireMapping.inventoryEvent(w).upsert(db)
        }

        for w in response.auditLogs {
            try WireMapping.auditLog(w).upsert(db)
        }

        if let profile = response.profile {
            try WireMapping.profile(profile, now: 0).upsert(db)
        }

        if let preferences = response.preferences {
            try WireMapping.settings(preferences).upsert(db)
        }

        try applyTombstones(db, response.tombstones)
    }

    /// Maps each tombstone's `entityType` to a local table via the
    /// whitelist and deletes the row by id. Unknown entity types are
    /// silently ignored.
    private static func applyTombstones(_ db: Database, _ tombstones: [WireTombstone]) throws {
        for t in tombstones {
            guard let table = tombstoneTables[t.entityType] else { continue }
            try db.execute(sql: "DELETE FROM \(table) WHERE id = ?", arguments: [t.entityId])
        }
    }
}
