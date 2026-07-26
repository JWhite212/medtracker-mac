import Foundation
import GRDB
import MedTrackerData

/// Cursor + epoch persistence for the `/api/v1` sync engine.
///
/// The `/api/v1` contract uses a single global cursor (the server's
/// response time) and an integer `epoch` shared across every table —
/// there are no per-table cursors. This reuses the Phase-1a
/// `MedTrackerData.SyncState` GRDB table (columns `table_name` /
/// `cursor` / `updated_at`) as a tiny key/value store, keyed by the
/// sentinel row names `"__cursor__"` and `"__epoch__"` (the epoch is
/// stored as a decimal string in the `cursor` column). Consumed by
/// `SyncEngine` (Task 15).
public struct SyncStateStore: Sendable {
    private static let cursorKey = "__cursor__"
    private static let epochKey = "__epoch__"

    private let dbWriter: any DatabaseWriter

    public init(dbWriter: any DatabaseWriter) {
        self.dbWriter = dbWriter
    }

    public func loadCursor() throws -> String? {
        try dbWriter.read { db in
            try SyncState.fetchOne(db, key: Self.cursorKey)?.cursor
        }
    }

    public func saveCursor(_ cursor: String) throws {
        try dbWriter.write { db in
            try SyncState(tableName: Self.cursorKey, cursor: cursor, updatedAt: 0).upsert(db)
        }
    }

    public func loadEpoch() throws -> Int {
        let stored = try dbWriter.read { db in
            try SyncState.fetchOne(db, key: Self.epochKey)?.cursor
        }
        return stored.flatMap { Int($0) } ?? 0
    }

    public func saveEpoch(_ epoch: Int) throws {
        try dbWriter.write { db in
            try SyncState(tableName: Self.epochKey, cursor: String(epoch), updatedAt: 0).upsert(db)
        }
    }

    /// Writes both `__cursor__` and `__epoch__` inside **one** `dbWriter.write` transaction, so
    /// a crash between the two writes can never leave a new cursor persisted with the old epoch
    /// (or vice versa) — `SyncEngine.sync()` uses this instead of two separate
    /// `saveCursor`/`saveEpoch` calls. Those two remain as independent methods for tests/callers
    /// that only need to set one of the pair.
    public func saveCursorAndEpoch(cursor: String, epoch: Int) throws {
        try dbWriter.write { db in
            try SyncState(tableName: Self.cursorKey, cursor: cursor, updatedAt: 0).upsert(db)
            try SyncState(tableName: Self.epochKey, cursor: String(epoch), updatedAt: 0).upsert(db)
        }
    }
}
