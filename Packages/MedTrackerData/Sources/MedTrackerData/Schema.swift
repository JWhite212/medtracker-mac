import Foundation
import GRDB

// MARK: - Timestamp convention
//
// Every timestamp column in this schema is a **UTC epoch-seconds `Double`**
// (SQLite `REAL`), not an ISO-8601 string and not GRDB's own default
// `Date` encoding. This is an explicit choice (see Task 13 of the Phase 1a
// plan): it keeps the wire format unambiguous and arithmetic-friendly
// (`Date(timeIntervalSince1970:)` round-trips exactly), and matches the
// `localDate` SQL function's expected input (`LocalDateFunction.swift`).
// Repositories (Task 14) convert to/from `Date` at the boundary.
//
// `dosageAmount` / `*IntervalHours` are stored as **TEXT** (mirroring the
// web's Drizzle `numeric` columns, which round-trip as strings) and are
// surfaced to callers via computed `Decimal` accessors on each record.
//
// `daysOfWeek` / `sideEffects` are stored as **JSON TEXT** columns, encoded
// and decoded explicitly (rather than relying on GRDB's automatic
// Codable-array-as-JSON behavior) so the exact JSON shape stays under our
// control and predictable for the future sync wire format.

// MARK: - Shared JSON value types

/// Mirrors the web's `dose_logs.side_effects` JSONB shape
/// (`{ name: string; severity: "mild" | "moderate" | "severe" }[]`,
/// `schema.ts:121-124`).
public struct SideEffectEntry: Codable, Equatable {
    public var name: String
    public var severity: String

    public init(name: String, severity: String) {
        self.name = name
        self.severity = severity
    }
}

// MARK: - medication

/// Mirrors the web's `medications` table (`schema.ts:66-105`).
public struct Medication: Codable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "medication"

    public var id: String
    public var userId: String
    public var name: String
    /// Decimal-as-text; see `dosageAmountDecimal`.
    public var dosageAmount: String
    public var dosageUnit: String
    public var form: String
    public var category: String
    public var colour: String
    public var colourSecondary: String?
    public var pattern: String
    public var notes: String?
    /// DEPRECATED on the web (kept for parity) — canonical source is
    /// `medication_schedule`.
    public var scheduleType: String
    /// DEPRECATED on the web; decimal-as-text.
    public var scheduleIntervalHours: String?
    public var inventoryCount: Int?
    public var inventoryAlertThreshold: Int?
    public var sortOrder: Int
    public var isArchived: Bool
    public var archivedAt: Double?
    public var startedAt: Double
    public var endedAt: Double?
    public var createdAt: Double
    public var updatedAt: Double

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case name
        case dosageAmount = "dosage_amount"
        case dosageUnit = "dosage_unit"
        case form
        case category
        case colour
        case colourSecondary = "colour_secondary"
        case pattern
        case notes
        case scheduleType = "schedule_type"
        case scheduleIntervalHours = "schedule_interval_hours"
        case inventoryCount = "inventory_count"
        case inventoryAlertThreshold = "inventory_alert_threshold"
        case sortOrder = "sort_order"
        case isArchived = "is_archived"
        case archivedAt = "archived_at"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public var dosageAmountDecimal: Decimal {
        Decimal(string: dosageAmount) ?? 0
    }

    public var scheduleIntervalHoursDecimal: Decimal? {
        scheduleIntervalHours.flatMap { Decimal(string: $0) }
    }

    public init(
        id: String,
        userId: String,
        name: String,
        dosageAmount: String,
        dosageUnit: String,
        form: String,
        category: String,
        colour: String,
        colourSecondary: String? = nil,
        pattern: String = "solid",
        notes: String? = nil,
        scheduleType: String = "scheduled",
        scheduleIntervalHours: String? = nil,
        inventoryCount: Int? = nil,
        inventoryAlertThreshold: Int? = nil,
        sortOrder: Int = 0,
        isArchived: Bool = false,
        archivedAt: Double? = nil,
        startedAt: Double,
        endedAt: Double? = nil,
        createdAt: Double,
        updatedAt: Double
    ) {
        self.id = id
        self.userId = userId
        self.name = name
        self.dosageAmount = dosageAmount
        self.dosageUnit = dosageUnit
        self.form = form
        self.category = category
        self.colour = colour
        self.colourSecondary = colourSecondary
        self.pattern = pattern
        self.notes = notes
        self.scheduleType = scheduleType
        self.scheduleIntervalHours = scheduleIntervalHours
        self.inventoryCount = inventoryCount
        self.inventoryAlertThreshold = inventoryAlertThreshold
        self.sortOrder = sortOrder
        self.isArchived = isArchived
        self.archivedAt = archivedAt
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - medication_schedule

/// Mirrors the web's `medication_schedules` table (`schema.ts:144-170`),
/// including the 3-way discriminated-union `CHECK` constraint enforced in
/// `Migrations.swift`. `scheduleKind` is the exact raw string
/// (`"interval" | "fixed_time" | "prn"`) used by
/// `MedTrackerCore.ScheduleKind`, kept as a plain `String` here (rather than
/// bridging the enum type itself) to keep this schema layer decoupled from
/// `MedTrackerCore`'s domain type.
public struct MedicationSchedule: Codable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "medication_schedule"

    public var id: String
    public var medicationId: String
    public var userId: String
    public var scheduleKind: String
    public var timeOfDay: String?
    /// Decimal-as-text; see `intervalHoursDecimal`.
    public var intervalHours: String?
    /// JSON-array-of-Int text, e.g. `"[1,3,5]"`; see `daysOfWeekArray`.
    public var daysOfWeek: String?
    public var sortOrder: Int
    public var effectiveFrom: Double
    public var effectiveTo: Double?
    public var createdAt: Double

    enum CodingKeys: String, CodingKey {
        case id
        case medicationId = "medication_id"
        case userId = "user_id"
        case scheduleKind = "schedule_kind"
        case timeOfDay = "time_of_day"
        case intervalHours = "interval_hours"
        case daysOfWeek = "days_of_week"
        case sortOrder = "sort_order"
        case effectiveFrom = "effective_from"
        case effectiveTo = "effective_to"
        case createdAt = "created_at"
    }

    public var intervalHoursDecimal: Decimal? {
        intervalHours.flatMap { Decimal(string: $0) }
    }

    public var daysOfWeekArray: [Int]? {
        guard let daysOfWeek, let data = daysOfWeek.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([Int].self, from: data)
    }

    public init(
        id: String,
        medicationId: String,
        userId: String,
        scheduleKind: String,
        timeOfDay: String? = nil,
        intervalHours: String? = nil,
        daysOfWeek: [Int]? = nil,
        sortOrder: Int = 0,
        effectiveFrom: Double,
        effectiveTo: Double? = nil,
        createdAt: Double
    ) {
        self.id = id
        self.medicationId = medicationId
        self.userId = userId
        self.scheduleKind = scheduleKind
        self.timeOfDay = timeOfDay
        self.intervalHours = intervalHours
        if let daysOfWeek, let data = try? JSONEncoder().encode(daysOfWeek) {
            self.daysOfWeek = String(data: data, encoding: .utf8)
        } else {
            self.daysOfWeek = nil
        }
        self.sortOrder = sortOrder
        self.effectiveFrom = effectiveFrom
        self.effectiveTo = effectiveTo
        self.createdAt = createdAt
    }
}

// MARK: - dose_log

/// Mirrors the web's `dose_logs` table (`schema.ts:107-131`). Note the web
/// schema has both `takenAt` (user-facing) and `updatedAt` (sync cursor) —
/// both are carried here.
public struct DoseLog: Codable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "dose_log"

    public var id: String
    public var userId: String
    public var medicationId: String
    public var quantity: Int
    public var takenAt: Double
    public var loggedAt: Double
    public var notes: String?
    /// JSON-array text; see `sideEffectsArray`.
    public var sideEffects: String?
    /// `"taken" | "skipped" | "missed"` — mirrors `DoseLogStatus`.
    public var status: String
    public var updatedAt: Double

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case medicationId = "medication_id"
        case quantity
        case takenAt = "taken_at"
        case loggedAt = "logged_at"
        case notes
        case sideEffects = "side_effects"
        case status
        case updatedAt = "updated_at"
    }

    public var sideEffectsArray: [SideEffectEntry]? {
        guard let sideEffects, let data = sideEffects.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([SideEffectEntry].self, from: data)
    }

    public init(
        id: String,
        userId: String,
        medicationId: String,
        quantity: Int = 1,
        takenAt: Double,
        loggedAt: Double,
        notes: String? = nil,
        sideEffects: [SideEffectEntry]? = nil,
        status: String = "taken",
        updatedAt: Double
    ) {
        self.id = id
        self.userId = userId
        self.medicationId = medicationId
        self.quantity = quantity
        self.takenAt = takenAt
        self.loggedAt = loggedAt
        self.notes = notes
        if let sideEffects, let data = try? JSONEncoder().encode(sideEffects) {
            self.sideEffects = String(data: data, encoding: .utf8)
        } else {
            self.sideEffects = nil
        }
        self.status = status
        self.updatedAt = updatedAt
    }
}

// MARK: - inventory_event

/// Mirrors the web's `inventory_events` table (`schema.ts:302-329`).
public struct InventoryEvent: Codable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "inventory_event"

    public var id: String
    public var userId: String
    public var medicationId: String
    /// `"dose_taken" | "dose_deleted" | "dose_quantity_updated" |
    /// "manual_adjustment" | "refill" | "correction"`.
    public var eventType: String
    public var quantityChange: Int
    public var previousCount: Int?
    public var newCount: Int?
    public var note: String?
    public var createdAt: Double

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case medicationId = "medication_id"
        case eventType = "event_type"
        case quantityChange = "quantity_change"
        case previousCount = "previous_count"
        case newCount = "new_count"
        case note
        case createdAt = "created_at"
    }

    public init(
        id: String,
        userId: String,
        medicationId: String,
        eventType: String,
        quantityChange: Int,
        previousCount: Int? = nil,
        newCount: Int? = nil,
        note: String? = nil,
        createdAt: Double
    ) {
        self.id = id
        self.userId = userId
        self.medicationId = medicationId
        self.eventType = eventType
        self.quantityChange = quantityChange
        self.previousCount = previousCount
        self.newCount = newCount
        self.note = note
        self.createdAt = createdAt
    }
}

// MARK: - audit_log

/// Mirrors the web's `audit_logs` table (`schema.ts:172-186`). `changes` is
/// arbitrary JSON (a diff object) stored as raw TEXT — its shape varies per
/// entity/action, so it is not modeled as a typed Swift value here.
public struct AuditLog: Codable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "audit_log"

    public var id: String
    public var userId: String
    public var entityType: String
    public var entityId: String
    public var action: String
    /// Raw JSON text (nullable), e.g. `{"before":...,"after":...}`.
    public var changes: String?
    public var createdAt: Double

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case entityType = "entity_type"
        case entityId = "entity_id"
        case action
        case changes
        case createdAt = "created_at"
    }

    public init(
        id: String,
        userId: String,
        entityType: String,
        entityId: String,
        action: String,
        changes: String? = nil,
        createdAt: Double
    ) {
        self.id = id
        self.userId = userId
        self.entityType = entityType
        self.entityId = entityId
        self.action = action
        self.changes = changes
        self.createdAt = createdAt
    }
}

// MARK: - reminder_event

/// Local notification **delivery ledger** — deliberately leaner than the
/// web's `reminder_events` table. The web's retry/email/push-channel
/// bookkeeping (`attemptCount`, `lastError`, `emailStatus`, `pushStatus`)
/// exists there solely to compensate for unreliable remote channels (cron +
/// email/push delivery); per the design spec §7.7, local
/// `UNUserNotificationCenter` delivery doesn't fail that way, so this table
/// only keeps what's needed for a "why didn't I get a reminder?" audit
/// trail: the dedupe-key identifier, the covered slot instant, and whether
/// it was delivered or suppressed (e.g. by a dose logged within ±1h).
public struct ReminderEvent: Codable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "reminder_event"

    public var id: String
    public var userId: String
    public var medicationId: String
    /// `"overdue" | "low_inventory"`.
    public var reminderType: String
    /// The web-format dedupe key, e.g.
    /// `"{userId}:{medicationId}:overdue:{kind}:{scheduleId}:{slotISO}"`.
    public var dedupeKey: String
    /// The UTC epoch instant of the slot/threshold this reminder covers.
    public var slotAt: Double
    /// `"delivered" | "suppressed"`.
    public var status: String
    public var createdAt: Double

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case medicationId = "medication_id"
        case reminderType = "reminder_type"
        case dedupeKey = "dedupe_key"
        case slotAt = "slot_at"
        case status
        case createdAt = "created_at"
    }

    public init(
        id: String,
        userId: String,
        medicationId: String,
        reminderType: String,
        dedupeKey: String,
        slotAt: Double,
        status: String = "delivered",
        createdAt: Double
    ) {
        self.id = id
        self.userId = userId
        self.medicationId = medicationId
        self.reminderType = reminderType
        self.dedupeKey = dedupeKey
        self.slotAt = slotAt
        self.status = status
        self.createdAt = createdAt
    }
}

// MARK: - profile (single-row table)

/// Local single-row identity/timezone table. `id` is always `1` (enforced
/// by a `CHECK` + `ON CONFLICT REPLACE` primary key — see
/// `SingleRowTables` in GRDB's docs). `userId` is the server-side account
/// id (from `/api/v1` auth), kept distinct from the local `id` so this row
/// round-trips against the web's `users` table without an id-mapping
/// layer. `timezone` is the IANA identifier threaded through every
/// `MedTrackerCore` function that needs the user's profile tz (Global
/// Constraints: never read `TimeZone.current` in a pure function).
public struct Profile: Codable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "profile"

    public var id: Int
    public var userId: String
    public var email: String
    public var name: String
    public var timezone: String
    public var createdAt: Double
    public var updatedAt: Double

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case email
        case name
        case timezone
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(
        id: Int = 1,
        userId: String,
        email: String,
        name: String,
        timezone: String = "UTC",
        createdAt: Double,
        updatedAt: Double
    ) {
        self.id = id
        self.userId = userId
        self.email = email
        self.name = name
        self.timezone = timezone
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - settings (single-row table)

/// Local single-row preferences table — mirrors the web's
/// `user_preferences` (`schema.ts:188-208`), collapsed per the design spec
/// §10.1: the web's four notification-channel booleans become two local
/// toggles (`overdueRemindersEnabled`, `lowInventoryAlertsEnabled`), since
/// the Mac app only has one channel (native notifications). Every other
/// default is carried over verbatim.
public struct Settings: Codable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "settings"

    public var id: Int
    public var accentColor: String
    public var dateFormat: String
    public var timeFormat: String
    public var uiDensity: String
    public var reducedMotion: Bool
    public var overdueRemindersEnabled: Bool
    public var lowInventoryAlertsEnabled: Bool
    public var doseLogPageSize: Int
    public var heatmapPeriod: Int
    public var exportFormat: String
    public var updatedAt: Double

    enum CodingKeys: String, CodingKey {
        case id
        case accentColor = "accent_color"
        case dateFormat = "date_format"
        case timeFormat = "time_format"
        case uiDensity = "ui_density"
        case reducedMotion = "reduced_motion"
        case overdueRemindersEnabled = "overdue_reminders_enabled"
        case lowInventoryAlertsEnabled = "low_inventory_alerts_enabled"
        case doseLogPageSize = "dose_log_page_size"
        case heatmapPeriod = "heatmap_period"
        case exportFormat = "export_format"
        case updatedAt = "updated_at"
    }

    public init(
        id: Int = 1,
        accentColor: String = "#6366f1",
        dateFormat: String = "DD/MM/YYYY",
        timeFormat: String = "12h",
        uiDensity: String = "comfortable",
        reducedMotion: Bool = false,
        overdueRemindersEnabled: Bool = true,
        lowInventoryAlertsEnabled: Bool = true,
        doseLogPageSize: Int = 20,
        heatmapPeriod: Int = 90,
        exportFormat: String = "pdf",
        updatedAt: Double
    ) {
        self.id = id
        self.accentColor = accentColor
        self.dateFormat = dateFormat
        self.timeFormat = timeFormat
        self.uiDensity = uiDensity
        self.reducedMotion = reducedMotion
        self.overdueRemindersEnabled = overdueRemindersEnabled
        self.lowInventoryAlertsEnabled = lowInventoryAlertsEnabled
        self.doseLogPageSize = doseLogPageSize
        self.heatmapPeriod = heatmapPeriod
        self.exportFormat = exportFormat
        self.updatedAt = updatedAt
    }
}

// MARK: - outbox (local-only)

/// Queued `/api/v1` commands awaiting push, keyed by a client-generated
/// idempotency key (Task 14/1b will drain this). Local-only — not part of
/// the synced schema.
public struct OutboxEntry: Codable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "outbox"

    public var id: String
    /// The `/api/v1` command name, e.g. `"log_dose"`, `"refill"`.
    public var commandType: String
    /// JSON-encoded command payload.
    public var payload: String
    public var idempotencyKey: String
    /// `"pending" | "sent" | "failed"`.
    public var status: String
    public var attemptCount: Int
    public var lastError: String?
    public var createdAt: Double

    enum CodingKeys: String, CodingKey {
        case id
        case commandType = "command_type"
        case payload
        case idempotencyKey = "idempotency_key"
        case status
        case attemptCount = "attempt_count"
        case lastError = "last_error"
        case createdAt = "created_at"
    }

    public init(
        id: String,
        commandType: String,
        payload: String,
        idempotencyKey: String,
        status: String = "pending",
        attemptCount: Int = 0,
        lastError: String? = nil,
        createdAt: Double
    ) {
        self.id = id
        self.commandType = commandType
        self.payload = payload
        self.idempotencyKey = idempotencyKey
        self.status = status
        self.attemptCount = attemptCount
        self.lastError = lastError
        self.createdAt = createdAt
    }
}

// MARK: - sync_state (local-only)

/// Per-table delta-sync cursor (the `updated_at` watermark from the last
/// successful pull). Local-only — not part of the synced schema.
public struct SyncState: Codable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "sync_state"

    public var tableName: String
    public var cursor: String?
    public var updatedAt: Double

    enum CodingKeys: String, CodingKey {
        case tableName = "table_name"
        case cursor
        case updatedAt = "updated_at"
    }

    public init(tableName: String, cursor: String? = nil, updatedAt: Double) {
        self.tableName = tableName
        self.cursor = cursor
        self.updatedAt = updatedAt
    }
}
