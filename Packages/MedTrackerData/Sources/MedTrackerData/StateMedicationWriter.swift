import Foundation
import GRDB
import MedTrackerCore

/// State-only optimistic writer for the sync path (§8-#5, §5.2.4). Unlike
/// `MedicationRepository`, it writes **no `audit_log`** and **no
/// `inventory_event`** and runs inside the CALLER's `Database`, so
/// `WriteCoordinator` can join it with the tx-joined outbox `enqueue` in one
/// transaction (§4.2). The per-kind `makeSchedule` normalization is re-exposed
/// public here (it is `private` on `MedicationRepository`) so the sync path can
/// build schedule rows without tripping the 3-way discriminated-union `CHECK`.
public enum StateMedicationWriter {
    /// Builds one persistable schedule row, normalizing the per-kind field
    /// shape exactly like `MedicationRepository.makeSchedule` /
    /// `buildScheduleRows` (`schedules.ts:60-78`): `time_of_day` only on
    /// `fixed_time`, `interval_hours` only on `interval`, `days_of_week` only on
    /// `fixed_time` with a non-empty array (empty `[]` → `nil`). Stray fields on
    /// the wrong kind are dropped here rather than tripping the `CHECK`.
    public static func makeSchedule(medicationId: String, userId: String,
                                    input: MedicationScheduleInput, createdAt: Double) -> MedicationSchedule {
        let isFixedTime = input.scheduleKind == "fixed_time"
        let isInterval = input.scheduleKind == "interval"

        let normalizedTimeOfDay = isFixedTime ? input.timeOfDay : nil
        let normalizedIntervalHours = isInterval ? input.intervalHours : nil
        let normalizedDaysOfWeek: [Int]? = {
            guard isFixedTime, let days = input.daysOfWeek, !days.isEmpty else { return nil }
            return days
        }()

        return MedicationSchedule(
            id: createId(),
            medicationId: medicationId,
            userId: userId,
            scheduleKind: input.scheduleKind,
            timeOfDay: normalizedTimeOfDay,
            intervalHours: normalizedIntervalHours,
            daysOfWeek: normalizedDaysOfWeek,
            sortOrder: input.sortOrder,
            effectiveFrom: input.effectiveFrom.timeIntervalSince1970,
            effectiveTo: input.effectiveTo?.timeIntervalSince1970,
            createdAt: createdAt
        )
    }

    /// State-only upsert of a medication + its full schedule set, inside the
    /// caller's transaction. `isCreate=true` inserts `id` (caller-generated);
    /// `isCreate=false` loads-and-guards ownership, updates the row, and
    /// replaces ALL schedule rows delete-then-insert — returning `nil` with no
    /// side effect when `id` isn't found/owned. Never writes `audit_log` or
    /// `inventory_event` (those arrive on the next delta pull).
    @discardableResult
    public static func upsert(_ db: Database, userId: String, id: String, isCreate: Bool,
                              fields: MedicationFields, schedules: [MedicationScheduleInput],
                              now: Date) throws -> Medication? {
        let nowEpoch = now.timeIntervalSince1970

        if isCreate {
            let med = Medication(
                id: id, userId: userId, name: fields.name,
                dosageAmount: fields.dosageAmount, dosageUnit: fields.dosageUnit,
                form: fields.form, category: fields.category, colour: fields.colour,
                colourSecondary: fields.colourSecondary, pattern: fields.pattern,
                notes: fields.notes, scheduleType: fields.scheduleType,
                scheduleIntervalHours: fields.scheduleIntervalHours,
                inventoryCount: fields.inventoryCount,
                inventoryAlertThreshold: fields.inventoryAlertThreshold,
                startedAt: nowEpoch, createdAt: nowEpoch, updatedAt: nowEpoch)
            try med.insert(db)
            for input in schedules {
                try makeSchedule(medicationId: id, userId: userId, input: input, createdAt: nowEpoch).insert(db)
            }
            return med
        }

        guard var existing = try Medication.fetchOwned(db, userId: userId, id: id) else {
            return nil
        }
        existing.name = fields.name
        existing.dosageAmount = fields.dosageAmount
        existing.dosageUnit = fields.dosageUnit
        existing.form = fields.form
        existing.category = fields.category
        existing.colour = fields.colour
        existing.colourSecondary = fields.colourSecondary
        existing.pattern = fields.pattern
        existing.notes = fields.notes
        existing.scheduleType = fields.scheduleType
        existing.scheduleIntervalHours = fields.scheduleIntervalHours
        existing.inventoryCount = fields.inventoryCount
        existing.inventoryAlertThreshold = fields.inventoryAlertThreshold
        existing.updatedAt = nowEpoch
        try existing.update(db)

        try MedicationSchedule
            .filter(Column("medication_id") == id)
            .filter(Column("user_id") == userId)
            .deleteAll(db)
        for input in schedules {
            try makeSchedule(medicationId: id, userId: userId, input: input, createdAt: nowEpoch).insert(db)
        }
        return existing
    }
}
