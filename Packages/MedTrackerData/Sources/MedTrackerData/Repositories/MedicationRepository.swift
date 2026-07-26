import Foundation
import GRDB
import MedTrackerCore

/// The editable fields of a medication, as supplied by a create/update
/// call. Mirrors the TS `MedicationInput` shape consumed by
/// `createMedicationWithSchedules`/`updateMedicationWithSchedules`
/// (`medications.ts:78-102, 197-253`) — everything except the id, owner,
/// lifecycle timestamps, sort order, and archive state, which the
/// repository manages itself.
public struct MedicationFields: Equatable {
    public var name: String
    public var dosageAmount: String
    public var dosageUnit: String
    public var form: String
    public var category: String
    public var colour: String
    public var colourSecondary: String?
    public var pattern: String
    public var notes: String?
    public var scheduleType: String
    public var scheduleIntervalHours: String?
    public var inventoryCount: Int?
    public var inventoryAlertThreshold: Int?

    public init(
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
        inventoryAlertThreshold: Int? = nil
    ) {
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
    }
}

/// One replacement schedule row, as supplied by a create/update call —
/// `medicationId` is deliberately absent (the repository assigns it, since
/// for a create it isn't known to the caller until the medication id is
/// generated). Mirrors the TS `ScheduleInput` consumed by
/// `buildScheduleRows` (`schedules.ts`).
public struct MedicationScheduleInput: Equatable {
    public var scheduleKind: String
    public var timeOfDay: String?
    public var intervalHours: String?
    public var daysOfWeek: [Int]?
    public var sortOrder: Int
    public var effectiveFrom: Date
    public var effectiveTo: Date?

    public init(
        scheduleKind: String,
        timeOfDay: String? = nil,
        intervalHours: String? = nil,
        daysOfWeek: [Int]? = nil,
        sortOrder: Int = 0,
        effectiveFrom: Date,
        effectiveTo: Date? = nil
    ) {
        self.scheduleKind = scheduleKind
        self.timeOfDay = timeOfDay
        self.intervalHours = intervalHours
        self.daysOfWeek = daysOfWeek
        self.sortOrder = sortOrder
        self.effectiveFrom = effectiveFrom
        self.effectiveTo = effectiveTo
    }
}

/// Transactional medication mutations. Ports
/// `src/lib/server/medications.ts` (web app `medication-tracker`) —
/// `createMedicationWithSchedules`/`updateMedicationWithSchedules`
/// (`:115-155, 197-253`) and `archiveMedication`/`unarchiveMedication`
/// (`:276-294`). Each mutation is one `dbWriter.write { }` transaction: the
/// medication row, its full schedule replacement set (delete-then-insert),
/// and its audit row commit or roll back together.
public struct MedicationRepository {
    private let dbWriter: any DatabaseWriter

    /// Test-only fault injection — see `DoseRepository.testFaultAfterMutation`
    /// for the contract. Never set outside `RepositoryTests.swift`.
    var testFaultAfterMutation: (() throws -> Void)?

    public init(dbWriter: any DatabaseWriter) {
        self.dbWriter = dbWriter
    }

    // MARK: - createMedicationWithSchedules

    /// Ports `createMedicationWithSchedules` (`medications.ts:115-155`).
    /// Inserts the medication row, its initial schedule rows (if any), and
    /// a `create` audit row — one transaction, so a failure partway
    /// through (e.g. a schedule row violating the 3-way discriminated-union
    /// `CHECK`) leaves no medication row behind either.
    @discardableResult
    public func createMedicationWithSchedules(
        userId: String,
        fields: MedicationFields,
        schedules: [MedicationScheduleInput],
        now: Date = Date()
    ) throws -> Medication {
        let id = createId()
        let nowEpoch = now.timeIntervalSince1970

        return try dbWriter.write { db in
            let med = Medication(
                id: id,
                userId: userId,
                name: fields.name,
                dosageAmount: fields.dosageAmount,
                dosageUnit: fields.dosageUnit,
                form: fields.form,
                category: fields.category,
                colour: fields.colour,
                colourSecondary: fields.colourSecondary,
                pattern: fields.pattern,
                notes: fields.notes,
                scheduleType: fields.scheduleType,
                scheduleIntervalHours: fields.scheduleIntervalHours,
                inventoryCount: fields.inventoryCount,
                inventoryAlertThreshold: fields.inventoryAlertThreshold,
                startedAt: nowEpoch,
                createdAt: nowEpoch,
                updatedAt: nowEpoch
            )
            try med.insert(db)

            for input in schedules {
                try Self.makeSchedule(medicationId: id, userId: userId, input: input, createdAt: nowEpoch).insert(db)
            }

            try AuditLog(
                id: createId(),
                userId: userId,
                entityType: "medication",
                entityId: id,
                action: "create",
                createdAt: nowEpoch
            ).insert(db)

            try testFaultAfterMutation?()

            return med
        }
    }

    // MARK: - updateMedicationWithSchedules

    /// Ports `updateMedicationWithSchedules` (`medications.ts:197-253`).
    /// Returns `nil` without any side effect when the medication doesn't
    /// exist (or isn't owned by `userId`). Replaces **all** schedule rows
    /// for the medication with the supplied set (delete-then-insert, not a
    /// diff) and appends an `update` audit row only when a medication field
    /// actually changed. One transaction: the medication update, the
    /// schedule replacement, and the audit row commit or roll back
    /// together — a schedule row that violates the `CHECK` constraint
    /// rolls back the medication update too, leaving both medication and
    /// schedules exactly as they were before the call.
    @discardableResult
    public func updateMedicationWithSchedules(
        userId: String,
        medicationId: String,
        fields: MedicationFields,
        schedules: [MedicationScheduleInput],
        now: Date = Date()
    ) throws -> Medication? {
        try dbWriter.write { db in
            guard var existing = try Self.fetchOwnedMedication(db, userId: userId, medicationId: medicationId) else {
                return nil
            }
            let before = existing
            let nowEpoch = now.timeIntervalSince1970

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
                .filter(Column("medication_id") == medicationId)
                .filter(Column("user_id") == userId)
                .deleteAll(db)

            for input in schedules {
                try Self.makeSchedule(medicationId: medicationId, userId: userId, input: input, createdAt: nowEpoch)
                    .insert(db)
            }

            if let changes = Self.computeChanges(before: before, after: existing) {
                try AuditLog(
                    id: createId(),
                    userId: userId,
                    entityType: "medication",
                    entityId: medicationId,
                    action: "update",
                    changes: changes,
                    createdAt: nowEpoch
                ).insert(db)
            }

            try testFaultAfterMutation?()

            return existing
        }
    }

    // MARK: - archive / unarchive

    /// Ports `archiveMedication` (`medications.ts:276-284`). Sets
    /// `isArchived = true`, stamps `archivedAt`/`updatedAt`, and appends an
    /// `update` audit row recording the `isArchived` transition. Returns
    /// `false` without any side effect when the medication doesn't exist —
    /// a deliberate strengthening over the TS, which issues an unconditional
    /// blind `UPDATE` + audit row even for a non-existent/non-owned id (a
    /// latent quirk of the web version, not reproduced here; see the
    /// task report for details).
    @discardableResult
    public func archiveMedication(userId: String, medicationId: String, now: Date = Date()) throws -> Bool {
        try setArchived(userId: userId, medicationId: medicationId, isArchived: true, now: now)
    }

    /// Ports `unarchiveMedication` (`medications.ts:286-294`).
    @discardableResult
    public func unarchiveMedication(userId: String, medicationId: String, now: Date = Date()) throws -> Bool {
        try setArchived(userId: userId, medicationId: medicationId, isArchived: false, now: now)
    }

    private func setArchived(userId: String, medicationId: String, isArchived: Bool, now: Date) throws -> Bool {
        try dbWriter.write { db in
            guard var med = try Self.fetchOwnedMedication(db, userId: userId, medicationId: medicationId) else {
                return false
            }
            let wasArchived = med.isArchived
            let nowEpoch = now.timeIntervalSince1970

            med.isArchived = isArchived
            med.archivedAt = isArchived ? nowEpoch : nil
            med.updatedAt = nowEpoch
            try med.update(db)

            try AuditLog(
                id: createId(),
                userId: userId,
                entityType: "medication",
                entityId: medicationId,
                action: "update",
                changes: #"{"isArchived":{"from":\#(wasArchived),"to":\#(isArchived)}}"#,
                createdAt: nowEpoch
            ).insert(db)

            try testFaultAfterMutation?()

            return true
        }
    }

    // MARK: - Helpers

    private static func fetchOwnedMedication(_ db: Database, userId: String, medicationId: String) throws -> Medication? {
        try Medication.filter(key: medicationId).filter(Column("user_id") == userId).fetchOne(db)
    }

    private static func makeSchedule(
        medicationId: String,
        userId: String,
        input: MedicationScheduleInput,
        createdAt: Double
    ) -> MedicationSchedule {
        MedicationSchedule(
            id: createId(),
            medicationId: medicationId,
            userId: userId,
            scheduleKind: input.scheduleKind,
            timeOfDay: input.timeOfDay,
            intervalHours: input.intervalHours,
            daysOfWeek: input.daysOfWeek,
            sortOrder: input.sortOrder,
            effectiveFrom: input.effectiveFrom.timeIntervalSince1970,
            effectiveTo: input.effectiveTo?.timeIntervalSince1970,
            createdAt: createdAt
        )
    }

    /// Minimal JSON-diff over the editable medication fields. Ports the
    /// intent of `computeChanges` (`audit.ts:19-28`) — `nil` when nothing
    /// changed, so `updateMedicationWithSchedules` never writes a no-op
    /// audit row.
    private static func computeChanges(before: Medication, after: Medication) -> String? {
        var changed: [String: [String: Any]] = [:]

        func diff(_ key: String, _ from: String, _ to: String) {
            if from != to { changed[key] = ["from": from, "to": to] }
        }
        func diffOptional(_ key: String, _ from: String?, _ to: String?) {
            if from != to { changed[key] = ["from": from ?? NSNull(), "to": to ?? NSNull()] }
        }
        func diffOptionalInt(_ key: String, _ from: Int?, _ to: Int?) {
            if from != to { changed[key] = ["from": from ?? NSNull(), "to": to ?? NSNull()] }
        }

        diff("name", before.name, after.name)
        diff("dosageAmount", before.dosageAmount, after.dosageAmount)
        diff("dosageUnit", before.dosageUnit, after.dosageUnit)
        diff("form", before.form, after.form)
        diff("category", before.category, after.category)
        diff("colour", before.colour, after.colour)
        diffOptional("colourSecondary", before.colourSecondary, after.colourSecondary)
        diff("pattern", before.pattern, after.pattern)
        diffOptional("notes", before.notes, after.notes)
        diff("scheduleType", before.scheduleType, after.scheduleType)
        diffOptional("scheduleIntervalHours", before.scheduleIntervalHours, after.scheduleIntervalHours)
        diffOptionalInt("inventoryCount", before.inventoryCount, after.inventoryCount)
        diffOptionalInt("inventoryAlertThreshold", before.inventoryAlertThreshold, after.inventoryAlertThreshold)

        guard !changed.isEmpty else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: changed) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
