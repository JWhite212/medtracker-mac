import Foundation
import GRDB

// Shared medication query helpers used across the repositories. Extracted so
// the identical owner-scoped fetch isn't copy-pasted into every repository
// that needs to load-and-guard a medication before mutating it.

extension Medication {
    /// Fetches the medication with primary key `id`, but only if it is owned
    /// by `userId` — the self-defending ownership check every repository runs
    /// before touching a medication (mirrors the web's `and(eq(id), eq(userId))`
    /// filter). Returns `nil` when the row doesn't exist or belongs to another
    /// user. Single source of truth for the exact predicate:
    /// `Medication.filter(key: id).filter(Column("user_id") == userId)`.
    static func fetchOwned(_ db: Database, userId: String, id: String) throws -> Medication? {
        try Medication.filter(key: id).filter(Column("user_id") == userId).fetchOne(db)
    }

    /// Active (non-archived) medications for `userId`, in display order.
    public static func fetchActive(_ db: Database, userId: String) throws -> [Medication] {
        try Medication
            .filter(Column("user_id") == userId)
            .filter(Column("is_archived") == false)
            .order(Column("sort_order"))
            .fetchAll(db)
    }

    /// Archived medications for `userId`, in display order.
    public static func fetchArchived(_ db: Database, userId: String) throws -> [Medication] {
        try Medication
            .filter(Column("user_id") == userId)
            .filter(Column("is_archived") == true)
            .order(Column("sort_order"))
            .fetchAll(db)
    }
}

extension MedicationSchedule {
    /// All of `userId`'s schedule rows, bucketed by `medication_id`. Rows within
    /// a bucket preserve the fetch order (`sort_order`, then `id` as a stable
    /// tiebreak) so the VM can render them deterministically.
    public static func groupedByMedication(_ db: Database, userId: String) throws -> [String: [MedicationSchedule]] {
        let rows = try MedicationSchedule
            .filter(Column("user_id") == userId)
            .order(Column("sort_order"), Column("id"))
            .fetchAll(db)
        return Dictionary(grouping: rows, by: \.medicationId)
    }
}

extension InventoryEvent {
    /// The inventory-event ledger for one medication, newest first. Note (§5.2.6):
    /// optimistic refill/adjust writes never insert a local `inventory_event`, so
    /// a just-made adjustment appears here only after the next `sync()` pull.
    public static func history(_ db: Database, userId: String, medicationId: String) throws -> [InventoryEvent] {
        try InventoryEvent
            .filter(Column("user_id") == userId)
            .filter(Column("medication_id") == medicationId)
            .order(Column("created_at").desc)
            .fetchAll(db)
    }
}
