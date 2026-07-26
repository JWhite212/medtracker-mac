import Foundation
import GRDB

/// Factory for the app's local GRDB `DatabaseQueue`: applies the `v1`
/// migrator, registers `localDate`, and turns on `foreign_keys` + WAL
/// (best-effort — SQLite silently keeps its in-memory journal mode for
/// `:memory:` databases regardless of the WAL pragma, which is why tests
/// opening an in-memory queue still pass).
public enum MedTrackerDatabase {
    /// Opens a `DatabaseQueue` at `path`, or an in-memory database when
    /// `path` is `nil` (used by tests), applies the `v1` migrations, and
    /// registers the `localDate` SQL function on every connection.
    public static func open(path: String? = nil) throws -> DatabaseQueue {
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            db.add(function: localDateFunction)
        }

        let dbQueue: DatabaseQueue
        if let path {
            dbQueue = try DatabaseQueue(path: path, configuration: configuration)
        } else {
            dbQueue = try DatabaseQueue(configuration: configuration)
        }

        let migrator = Migrations.migrator()
        try migrator.migrate(dbQueue)

        return dbQueue
    }
}
