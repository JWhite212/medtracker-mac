import Foundation
import MedTrackerData

/// Errors raised while converting Task-3 wire DTOs to `MedTrackerData` GRDB
/// records.
public enum WireMappingError: Error, Equatable {
    case badDate(String)
}

/// Pure converters from the `/api/v1` wire DTOs (`WireModels.swift`) to the
/// local `MedTrackerData` GRDB records. No I/O, no side effects — every
/// function is a deterministic mapping over its input.
public enum WireMapping {
    /// Fractional ISO-8601 (`2026-07-26T10:00:00.000Z`), tried first since
    /// the web emits fractional seconds on most timestamps.
    private static let fractionalFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Plain ISO-8601 (`2026-07-26T10:00:00Z`), tried as a fallback.
    private static let plainFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Parses an ISO-8601 date string to a UTC epoch-seconds `Double`,
    /// trying the fractional formatter first and falling back to the plain
    /// one. Throws `.badDate` if neither parses.
    static func epoch(_ iso: String) throws -> Double {
        if let date = fractionalFormatter.date(from: iso) {
            return date.timeIntervalSince1970
        }
        if let date = plainFormatter.date(from: iso) {
            return date.timeIntervalSince1970
        }
        throw WireMappingError.badDate(iso)
    }

    /// `epoch(_:)` lifted over `String?`.
    static func epochOpt(_ iso: String?) throws -> Double? {
        guard let iso else { return nil }
        return try epoch(iso)
    }

    /// Converts a `WireMedication` to a `Medication` record. Numeric-as-
    /// string fields (`dosageAmount`, `scheduleIntervalHours`) pass through
    /// unchanged. Nested `schedules` are not mapped here — callers map them
    /// separately via `schedule(_:)`.
    static func medication(_ w: WireMedication) throws -> Medication {
        try Medication(
            id: w.id,
            userId: w.userId,
            name: w.name,
            dosageAmount: w.dosageAmount,
            dosageUnit: w.dosageUnit,
            form: w.form,
            category: w.category,
            colour: w.colour,
            colourSecondary: w.colourSecondary,
            pattern: w.pattern,
            notes: w.notes,
            scheduleType: w.scheduleType,
            scheduleIntervalHours: w.scheduleIntervalHours,
            inventoryCount: w.inventoryCount,
            inventoryAlertThreshold: w.inventoryAlertThreshold,
            sortOrder: w.sortOrder,
            isArchived: w.isArchived,
            archivedAt: epochOpt(w.archivedAt),
            startedAt: epoch(w.startedAt),
            endedAt: epochOpt(w.endedAt),
            createdAt: epoch(w.createdAt),
            updatedAt: epoch(w.updatedAt)
        )
    }

    /// Converts a `WireSchedule` to a `MedicationSchedule` record.
    /// `intervalHours` (numeric-as-string) passes through unchanged;
    /// `daysOfWeek` is passed as `[Int]?` to the `MedicationSchedule` init,
    /// which JSON-encodes it internally.
    static func schedule(_ w: WireSchedule) throws -> MedicationSchedule {
        try MedicationSchedule(
            id: w.id,
            medicationId: w.medicationId,
            userId: w.userId,
            scheduleKind: w.scheduleKind,
            timeOfDay: w.timeOfDay,
            intervalHours: w.intervalHours,
            daysOfWeek: w.daysOfWeek,
            sortOrder: w.sortOrder,
            effectiveFrom: epoch(w.effectiveFrom),
            effectiveTo: epochOpt(w.effectiveTo),
            createdAt: epoch(w.createdAt)
        )
    }

    /// Converts a `WireDoseLog` to a `DoseLog` record. `sideEffects` maps
    /// to `[SideEffectEntry]`.
    static func doseLog(_ w: WireDoseLog) throws -> DoseLog {
        try DoseLog(
            id: w.id,
            userId: w.userId,
            medicationId: w.medicationId,
            quantity: w.quantity,
            takenAt: epoch(w.takenAt),
            loggedAt: epoch(w.loggedAt),
            notes: w.notes,
            sideEffects: w.sideEffects?.map { SideEffectEntry(name: $0.name, severity: $0.severity) },
            status: w.status,
            updatedAt: epoch(w.updatedAt)
        )
    }

    /// Converts a `WireInventoryEvent` to an `InventoryEvent` record.
    static func inventoryEvent(_ w: WireInventoryEvent) throws -> InventoryEvent {
        try InventoryEvent(
            id: w.id,
            userId: w.userId,
            medicationId: w.medicationId,
            eventType: w.eventType,
            quantityChange: w.quantityChange,
            previousCount: w.previousCount,
            newCount: w.newCount,
            note: w.note,
            createdAt: epoch(w.createdAt)
        )
    }

    /// Converts a `WireAuditLog` to an `AuditLog` record. `changes` (typed
    /// `JSONValue?` on the wire) is re-serialized to raw JSON text, matching
    /// `AuditLog.changes`'s untyped-TEXT storage.
    static func auditLog(_ w: WireAuditLog) throws -> AuditLog {
        var changesText: String?
        if let changes = w.changes {
            let data = try JSONEncoder().encode(changes)
            changesText = String(data: data, encoding: .utf8)
        }
        return try AuditLog(
            id: w.id,
            userId: w.userId,
            entityType: w.entityType,
            entityId: w.entityId,
            action: w.action,
            changes: changesText,
            createdAt: epoch(w.createdAt)
        )
    }

    /// Builds the local single-row `Profile` from the auth session user.
    /// `now` is supplied by the caller (Global Constraints: no `Date()` in
    /// pure functions) and used for both `createdAt`/`updatedAt`.
    static func profile(_ u: SessionUser, now: Double) -> Profile {
        Profile(userId: u.id, email: u.email, name: u.name, timezone: u.timezone, createdAt: now, updatedAt: now)
    }

    /// Converts a `WirePreferences` to the local single-row `Settings`
    /// record, collapsing the web's 4 notification-channel booleans into
    /// the local 2 (`email || push` per channel).
    static func settings(_ p: WirePreferences) throws -> Settings {
        try Settings(
            accentColor: p.accentColor,
            dateFormat: p.dateFormat,
            timeFormat: p.timeFormat,
            uiDensity: p.uiDensity,
            reducedMotion: p.reducedMotion,
            overdueRemindersEnabled: p.overdueEmailReminders || p.overduePushReminders,
            lowInventoryAlertsEnabled: p.lowInventoryEmailAlerts || p.lowInventoryPushAlerts,
            doseLogPageSize: p.doseLogPageSize,
            heatmapPeriod: p.heatmapPeriod,
            exportFormat: p.exportFormat,
            updatedAt: epoch(p.updatedAt)
        )
    }
}
