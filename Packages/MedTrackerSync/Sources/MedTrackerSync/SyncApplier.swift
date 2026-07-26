import Foundation
import GRDB
import MedTrackerData

/// Applies a `GET /sync` response (contract §3) to the local GRDB replica.
///
/// `apply(_:)` runs the whole response in a single `dbWriter.write { db in
/// ... }` transaction and branches on `response.fullResync`:
/// - `false` — the delta-apply branch: per-row upserts, plus a wholesale
///   replace of each touched medication's `medication_schedule` rows, plus
///   tombstone deletes.
/// - `true` — the full-resync branch: wipes every synced table and reloads
///   it wholesale from the response. Tombstones are ignored on full resync
///   (the wholesale replace already reflects the server's current state).
///   Local-only tables (`OutboxEntry`, `SyncState`, `ReminderEvent`) are
///   never touched by either branch.
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

    /// The `fullResync == true` branch (contract §3 full-resync rules).
    /// Wipes every synced table (children first, then parents, so no FK
    /// violates mid-delete even though the schema's cascades would also
    /// cover it), then inserts the response wholesale: medications first
    /// (so their schedules' FKs hold), then dose logs / inventory events /
    /// audit logs, then profile / preferences. Tombstones are ignored — a
    /// full resync already reflects the server's current state, so there's
    /// nothing left for a tombstone to delete. Runs inside the caller's
    /// `dbWriter.write` transaction, so any failure (e.g. a bad FK) rolls
    /// back everything, including the wipe.
    private static func applyFull(_ db: Database, _ response: SyncResponse) throws {
        try DoseLog.deleteAll(db)
        try InventoryEvent.deleteAll(db)
        try AuditLog.deleteAll(db)
        try MedicationSchedule.deleteAll(db)
        try Medication.deleteAll(db)
        try Profile.deleteAll(db)
        try Settings.deleteAll(db)

        for w in response.medications {
            try WireMapping.medication(w).insert(db)
            for s in w.schedules {
                try WireMapping.schedule(s).insert(db)
            }
        }

        for w in response.doseLogs {
            try WireMapping.doseLog(w).insert(db)
        }

        for w in response.inventoryEvents {
            try WireMapping.inventoryEvent(w).insert(db)
        }

        for w in response.auditLogs {
            try WireMapping.auditLog(w).insert(db)
        }

        if let profile = response.profile {
            try WireMapping.profile(profile, now: 0).insert(db)
        }

        if let preferences = response.preferences {
            try WireMapping.settings(preferences).insert(db)
        }
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
