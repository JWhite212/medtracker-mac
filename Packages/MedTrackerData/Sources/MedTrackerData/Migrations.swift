import Foundation
import GRDB

/// The `v1` schema for the local GRDB/SQLite replica. Mirrors the web app's
/// Drizzle/Postgres schema (`medication-tracker/src/lib/server/db/schema.ts`)
/// table-for-table where synced, plus two local-only tables (`outbox`,
/// `sync_state`) for the future sync engine (Phase 1b). See `Schema.swift`
/// for the timestamp/decimal/JSON storage conventions and per-table record
/// types.
public enum Migrations {
    /// Builds the migrator. Callers apply it with `try migrator.migrate(db)`.
    public static func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try createMedicationTable(db)
            try createMedicationScheduleTable(db)
            try createDoseLogTable(db)
            try createInventoryEventTable(db)
            try createAuditLogTable(db)
            try createReminderEventTable(db)
            try createProfileTable(db)
            try createSettingsTable(db)
            try createOutboxTable(db)
            try createSyncStateTable(db)
        }

        return migrator
    }

    // MARK: - medication

    private static func createMedicationTable(_ db: Database) throws {
        try db.create(table: Medication.databaseTableName) { t in
            t.primaryKey("id", .text)
            t.column("user_id", .text).notNull()
            t.column("name", .text).notNull()
            t.column("dosage_amount", .text).notNull()
            t.column("dosage_unit", .text).notNull()
            t.column("form", .text).notNull()
            t.column("category", .text).notNull()
            t.column("colour", .text).notNull()
            t.column("colour_secondary", .text)
            t.column("pattern", .text).notNull().defaults(to: "solid")
            t.column("notes", .text)
            t.column("schedule_type", .text).notNull().defaults(to: "scheduled")
            t.column("schedule_interval_hours", .text)
            t.column("inventory_count", .integer)
            t.column("inventory_alert_threshold", .integer)
            t.column("sort_order", .integer).notNull().defaults(to: 0)
            t.column("is_archived", .boolean).notNull().defaults(to: false)
            t.column("archived_at", .double)
            t.column("started_at", .double).notNull()
            t.column("ended_at", .double)
            t.column("created_at", .double).notNull()
            t.column("updated_at", .double).notNull()
        }
        try db.create(
            index: "medication_user_archived_idx",
            on: Medication.databaseTableName,
            columns: ["user_id", "is_archived"]
        )
        try db.create(
            index: "medication_user_name_idx",
            on: Medication.databaseTableName,
            columns: ["user_id", "name"]
        )
        try db.create(
            index: "medication_user_started_idx",
            on: Medication.databaseTableName,
            columns: ["user_id", "started_at"]
        )
    }

    // MARK: - medication_schedule

    /// The 3-way discriminated-union `CHECK`, ported verbatim from the plan
    /// (mirroring the intent of the web's Zod schema for
    /// `medication_schedules`, `schema.ts:144-170`):
    /// - `interval`   → `interval_hours` present, `time_of_day` absent
    /// - `fixed_time` → `time_of_day` present, `interval_hours` absent
    /// - `prn`        → both absent
    private static func createMedicationScheduleTable(_ db: Database) throws {
        try db.create(table: MedicationSchedule.databaseTableName) { t in
            t.primaryKey("id", .text)
            t.column("medication_id", .text).notNull().indexed()
            t.column("user_id", .text).notNull()
            t.column("schedule_kind", .text).notNull()
            t.column("time_of_day", .text)
            t.column("interval_hours", .text)
            t.column("days_of_week", .text)
            t.column("sort_order", .integer).notNull().defaults(to: 0)
            t.column("effective_from", .double).notNull()
            t.column("effective_to", .double)
            t.column("created_at", .double).notNull()

            t.foreignKey(["medication_id"], references: Medication.databaseTableName, onDelete: .cascade)

            t.constraint(sql: """
            CHECK (
                (schedule_kind = 'interval' AND interval_hours IS NOT NULL AND time_of_day IS NULL)
                OR (schedule_kind = 'fixed_time' AND time_of_day IS NOT NULL AND interval_hours IS NULL)
                OR (schedule_kind = 'prn' AND interval_hours IS NULL AND time_of_day IS NULL)
            )
            """)
        }
        try db.create(
            index: "medication_schedule_user_idx",
            on: MedicationSchedule.databaseTableName,
            columns: ["user_id"]
        )
        try db.create(
            index: "medication_schedule_med_effective_idx",
            on: MedicationSchedule.databaseTableName,
            columns: ["medication_id", "effective_from"]
        )
    }

    // MARK: - dose_log

    private static func createDoseLogTable(_ db: Database) throws {
        try db.create(table: DoseLog.databaseTableName) { t in
            t.primaryKey("id", .text)
            t.column("user_id", .text).notNull()
            t.column("medication_id", .text).notNull().indexed()
            t.column("quantity", .integer).notNull().defaults(to: 1)
            t.column("taken_at", .double).notNull()
            t.column("logged_at", .double).notNull()
            t.column("notes", .text)
            t.column("side_effects", .text)
            t.column("status", .text).notNull().defaults(to: "taken")
            t.column("updated_at", .double).notNull()

            t.foreignKey(["medication_id"], references: Medication.databaseTableName, onDelete: .cascade)
        }
        try db.create(
            index: "dose_log_user_taken_idx",
            on: DoseLog.databaseTableName,
            columns: ["user_id", "taken_at"]
        )
        try db.create(
            index: "dose_log_med_taken_idx",
            on: DoseLog.databaseTableName,
            columns: ["medication_id", "taken_at"]
        )
        try db.create(
            index: "dose_log_user_status_taken_idx",
            on: DoseLog.databaseTableName,
            columns: ["user_id", "status", "taken_at"]
        )
        try db.create(
            index: "dose_log_user_updated_idx",
            on: DoseLog.databaseTableName,
            columns: ["user_id", "updated_at"]
        )
    }

    // MARK: - inventory_event

    private static func createInventoryEventTable(_ db: Database) throws {
        try db.create(table: InventoryEvent.databaseTableName) { t in
            t.primaryKey("id", .text)
            t.column("user_id", .text).notNull()
            t.column("medication_id", .text).notNull().indexed()
            t.column("event_type", .text).notNull()
            t.column("quantity_change", .integer).notNull()
            t.column("previous_count", .integer)
            t.column("new_count", .integer)
            t.column("note", .text)
            t.column("created_at", .double).notNull()

            t.foreignKey(["medication_id"], references: Medication.databaseTableName, onDelete: .cascade)
        }
        try db.create(
            index: "inventory_event_user_created_idx",
            on: InventoryEvent.databaseTableName,
            columns: ["user_id", "created_at"]
        )
        try db.create(
            index: "inventory_event_med_created_idx",
            on: InventoryEvent.databaseTableName,
            columns: ["medication_id", "created_at"]
        )
    }

    // MARK: - audit_log
    //
    // No FK on `entity_id` — it's polymorphic (medication / dose_log /
    // medication_schedule / ...), matching the web's `audit_logs` table
    // which has the same shape and the same lack of an FK there.

    private static func createAuditLogTable(_ db: Database) throws {
        try db.create(table: AuditLog.databaseTableName) { t in
            t.primaryKey("id", .text)
            t.column("user_id", .text).notNull()
            t.column("entity_type", .text).notNull()
            t.column("entity_id", .text).notNull()
            t.column("action", .text).notNull()
            t.column("changes", .text)
            t.column("created_at", .double).notNull()
        }
        try db.create(
            index: "audit_log_user_created_idx",
            on: AuditLog.databaseTableName,
            columns: ["user_id", "created_at"]
        )
    }

    // MARK: - reminder_event

    private static func createReminderEventTable(_ db: Database) throws {
        try db.create(table: ReminderEvent.databaseTableName) { t in
            t.primaryKey("id", .text)
            t.column("user_id", .text).notNull()
            t.column("medication_id", .text).notNull().indexed()
            t.column("reminder_type", .text).notNull()
            t.column("dedupe_key", .text).notNull().unique()
            t.column("slot_at", .double).notNull()
            t.column("status", .text).notNull().defaults(to: "delivered")
            t.column("created_at", .double).notNull()

            t.foreignKey(["medication_id"], references: Medication.databaseTableName, onDelete: .cascade)
        }
        try db.create(
            index: "reminder_event_user_created_idx",
            on: ReminderEvent.databaseTableName,
            columns: ["user_id", "created_at"]
        )
    }

    // MARK: - profile (single row)

    private static func createProfileTable(_ db: Database) throws {
        try db.create(table: Profile.databaseTableName) { t in
            t.primaryKey("id", .integer, onConflict: .replace).check { $0 == 1 }
            t.column("user_id", .text).notNull()
            t.column("email", .text).notNull()
            t.column("name", .text).notNull()
            t.column("timezone", .text).notNull().defaults(to: "UTC")
            t.column("created_at", .double).notNull()
            t.column("updated_at", .double).notNull()
        }
    }

    // MARK: - settings (single row)

    private static func createSettingsTable(_ db: Database) throws {
        try db.create(table: Settings.databaseTableName) { t in
            t.primaryKey("id", .integer, onConflict: .replace).check { $0 == 1 }
            t.column("accent_color", .text).notNull().defaults(to: "#6366f1")
            t.column("date_format", .text).notNull().defaults(to: "DD/MM/YYYY")
            t.column("time_format", .text).notNull().defaults(to: "12h")
            t.column("ui_density", .text).notNull().defaults(to: "comfortable")
            t.column("reduced_motion", .boolean).notNull().defaults(to: false)
            t.column("overdue_reminders_enabled", .boolean).notNull().defaults(to: true)
            t.column("low_inventory_alerts_enabled", .boolean).notNull().defaults(to: true)
            t.column("dose_log_page_size", .integer).notNull().defaults(to: 20)
            t.column("heatmap_period", .integer).notNull().defaults(to: 90)
            t.column("export_format", .text).notNull().defaults(to: "pdf")
            t.column("updated_at", .double).notNull()
        }
    }

    // MARK: - outbox (local-only)

    private static func createOutboxTable(_ db: Database) throws {
        try db.create(table: OutboxEntry.databaseTableName) { t in
            t.primaryKey("id", .text)
            t.column("command_type", .text).notNull()
            t.column("payload", .text).notNull()
            t.column("idempotency_key", .text).notNull().unique()
            t.column("status", .text).notNull().defaults(to: "pending")
            t.column("attempt_count", .integer).notNull().defaults(to: 0)
            t.column("last_error", .text)
            t.column("created_at", .double).notNull()
        }
        try db.create(
            index: "outbox_status_idx",
            on: OutboxEntry.databaseTableName,
            columns: ["status"]
        )
    }

    // MARK: - sync_state (local-only)

    private static func createSyncStateTable(_ db: Database) throws {
        try db.create(table: SyncState.databaseTableName) { t in
            t.primaryKey("table_name", .text)
            t.column("cursor", .text)
            t.column("updated_at", .double).notNull()
        }
    }
}
