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
}
