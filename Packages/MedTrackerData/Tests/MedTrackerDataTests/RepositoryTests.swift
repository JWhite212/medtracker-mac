import Foundation
import GRDB
@testable import MedTrackerData
import Testing

// Task 14: transactional dose/inventory/medication repository tests, against
// a real in-memory GRDB/SQLite database (via `MedTrackerDatabase.open()`).
// Transcribes the intent of `tests/unit/doses-inventory.test.ts` and
// `tests/unit/inventory-events.test.ts` — but against a real database rather
// than a mocked query builder, which is strictly stronger: the atomic-
// rollback tests below prove actual SQLite transaction rollback, not just
// "the mock wasn't called".

private let now = Date()
private let nowEpoch = now.timeIntervalSince1970

private func makeMedication(id: String = "med_1", inventoryCount: Int? = nil) -> Medication {
    Medication(
        id: id,
        userId: "user_1",
        name: "Ibuprofen",
        dosageAmount: "200",
        dosageUnit: "mg",
        form: "tablet",
        category: "otc",
        colour: "#ff0000",
        inventoryCount: inventoryCount,
        startedAt: nowEpoch,
        createdAt: nowEpoch,
        updatedAt: nowEpoch
    )
}

private func makeDose(
    id: String = "dose_1",
    medicationId: String = "med_1",
    quantity: Int = 1,
    status: String = "taken",
    notes: String? = nil
) -> DoseLog {
    DoseLog(
        id: id,
        userId: "user_1",
        medicationId: medicationId,
        quantity: quantity,
        takenAt: nowEpoch,
        loggedAt: nowEpoch,
        notes: notes,
        sideEffects: nil,
        status: status,
        updatedAt: nowEpoch
    )
}

private struct InjectedFailure: Error, Equatable {}

/// Runs `body`, asserting it throws exactly `expected` (by `Equatable`
/// value, not just dynamic type — distinguishes sibling cases of the same
/// error enum, e.g. `.invalidRefillQuantity` vs. `.medicationNotFound`).
private func expectThrows<E: Error & Equatable>(_ expected: E, _ body: () throws -> Void) {
    do {
        try body()
        Issue.record("expected \(expected) to be thrown, but no error was thrown")
    } catch let error as E {
        #expect(error == expected)
    } catch {
        Issue.record("expected \(expected), got \(error)")
    }
}

struct RepositoryTests {
    // MARK: - DoseRepository.logDose

    @Test func logDose_decrementsInventoryClampedAtZero_andRecordsClampedEventDelta() throws {
        let db = try MedTrackerDatabase.open()
        try db.write { d in try makeMedication(inventoryCount: 2).insert(d) }

        let repo = DoseRepository(dbWriter: db)
        let dose = try repo.logDose(userId: "user_1", medicationId: "med_1", quantity: 5)
        #expect(dose.status == "taken")
        #expect(dose.quantity == 5)

        let med = try db.read { d in try Medication.filter(key: "med_1").fetchOne(d) }
        #expect(med?.inventoryCount == 0) // max(0, 2 - 5) = 0

        let events = try db.read { d in try InventoryEvent.fetchAll(d) }
        #expect(events.count == 1)
        guard let event = events.first else { return }
        #expect(event.eventType == "dose_taken")
        #expect(event.previousCount == 2)
        #expect(event.newCount == 0)
        #expect(event.quantityChange == -2) // clamped actual change, NOT -5

        #expect(try db.read { d in try DoseLog.fetchCount(d) } == 1)
        #expect(try db.read { d in try AuditLog.fetchCount(d) } == 1)
    }

    @Test func logDose_normalDecrement_eventDeltaEqualsNegativeQuantity() throws {
        let db = try MedTrackerDatabase.open()
        try db.write { d in try makeMedication(inventoryCount: 30).insert(d) }

        let repo = DoseRepository(dbWriter: db)
        try repo.logDose(userId: "user_1", medicationId: "med_1", quantity: 1)

        let events = try db.read { d in try InventoryEvent.fetchAll(d) }
        guard let event = events.first else { Issue.record("expected an event"); return }
        #expect(event.previousCount == 30)
        #expect(event.newCount == 29)
        #expect(event.quantityChange == -1)
    }

    @Test func logDose_untrackedMedication_recordsNoEvent() throws {
        let db = try MedTrackerDatabase.open()
        try db.write { d in try makeMedication(inventoryCount: nil).insert(d) }

        let repo = DoseRepository(dbWriter: db)
        try repo.logDose(userId: "user_1", medicationId: "med_1", quantity: 1)

        #expect(try db.read { d in try InventoryEvent.fetchCount(d) } == 0)
        let med = try db.read { d in try Medication.filter(key: "med_1").fetchOne(d) }
        #expect(med?.inventoryCount == nil)
        #expect(try db.read { d in try DoseLog.fetchCount(d) } == 1)
    }

    @Test func logDose_throwsForUnknownMedication() throws {
        let db = try MedTrackerDatabase.open()
        let repo = DoseRepository(dbWriter: db)
        expectThrows(DoseRepositoryError.medicationNotFound) {
            try repo.logDose(userId: "user_1", medicationId: "missing", quantity: 1)
        }
        #expect(try db.read { d in try DoseLog.fetchCount(d) } == 0)
    }

    // MARK: - DoseRepository.logSkippedDose

    @Test func logSkippedDose_noInventoryChangeAndNoEvent() throws {
        let db = try MedTrackerDatabase.open()
        try db.write { d in try makeMedication(inventoryCount: 10).insert(d) }

        let repo = DoseRepository(dbWriter: db)
        let dose = try repo.logSkippedDose(userId: "user_1", medicationId: "med_1")
        #expect(dose.status == "skipped")
        #expect(dose.quantity == 1)

        let med = try db.read { d in try Medication.filter(key: "med_1").fetchOne(d) }
        #expect(med?.inventoryCount == 10)
        #expect(try db.read { d in try InventoryEvent.fetchCount(d) } == 0)
        #expect(try db.read { d in try AuditLog.fetchCount(d) } == 1)
    }

    // MARK: - DoseRepository.deleteDose

    @Test func deleteDose_restoresInventoryUnclampedForTakenDose() throws {
        let db = try MedTrackerDatabase.open()
        try db.write { d in
            try makeMedication(inventoryCount: 5).insert(d)
            try makeDose(quantity: 10, status: "taken").insert(d)
        }

        let repo = DoseRepository(dbWriter: db)
        let ok = try repo.deleteDose(userId: "user_1", doseId: "dose_1")
        #expect(ok == true)

        let med = try db.read { d in try Medication.filter(key: "med_1").fetchOne(d) }
        // 5 + 10 = 15 — unclamped, deliberately no upper bound (unlike the clamped decrement).
        #expect(med?.inventoryCount == 15)

        let events = try db.read { d in try InventoryEvent.fetchAll(d) }
        #expect(events.count == 1)
        guard let event = events.first else { return }
        #expect(event.eventType == "dose_deleted")
        #expect(event.quantityChange == 10)
        #expect(event.previousCount == 5)
        #expect(event.newCount == 15)

        #expect(try db.read { d in try DoseLog.fetchCount(d) } == 0)
    }

    @Test func deleteDose_skippedDose_doesNotRestoreInventory() throws {
        let db = try MedTrackerDatabase.open()
        try db.write { d in
            try makeMedication(inventoryCount: 5).insert(d)
            try makeDose(quantity: 1, status: "skipped").insert(d)
        }

        let repo = DoseRepository(dbWriter: db)
        let ok = try repo.deleteDose(userId: "user_1", doseId: "dose_1")
        #expect(ok == true)

        let med = try db.read { d in try Medication.filter(key: "med_1").fetchOne(d) }
        #expect(med?.inventoryCount == 5)
        #expect(try db.read { d in try InventoryEvent.fetchCount(d) } == 0)
    }

    @Test func deleteDose_missedDose_doesNotRestoreInventory() throws {
        let db = try MedTrackerDatabase.open()
        try db.write { d in
            try makeMedication(inventoryCount: 5).insert(d)
            try makeDose(quantity: 1, status: "missed").insert(d)
        }

        let repo = DoseRepository(dbWriter: db)
        let ok = try repo.deleteDose(userId: "user_1", doseId: "dose_1")
        #expect(ok == true)

        let med = try db.read { d in try Medication.filter(key: "med_1").fetchOne(d) }
        #expect(med?.inventoryCount == 5)
        #expect(try db.read { d in try InventoryEvent.fetchCount(d) } == 0)
    }

    @Test func deleteDose_returnsFalseWhenDoseDoesNotExist() throws {
        let db = try MedTrackerDatabase.open()
        let repo = DoseRepository(dbWriter: db)
        let ok = try repo.deleteDose(userId: "user_1", doseId: "missing")
        #expect(ok == false)
        #expect(try db.read { d in try AuditLog.fetchCount(d) } == 0)
    }

    // MARK: - DoseRepository.updateDose

    @Test func updateDose_adjustsInventoryOnlyWhenTakenAndQuantityChanged_clampedDelta() throws {
        let db = try MedTrackerDatabase.open()
        try db.write { d in
            try makeMedication(inventoryCount: 2).insert(d)
            try makeDose(quantity: 1, status: "taken").insert(d)
        }

        let repo = DoseRepository(dbWriter: db)
        // diff = 5 - 1 = 4; newCount = max(0, 2 - 4) = 0 (clamped)
        let updated = try repo.updateDose(userId: "user_1", doseId: "dose_1", quantity: 5)
        #expect(updated?.quantity == 5)

        let med = try db.read { d in try Medication.filter(key: "med_1").fetchOne(d) }
        #expect(med?.inventoryCount == 0)

        let events = try db.read { d in try InventoryEvent.fetchAll(d) }
        #expect(events.count == 1)
        guard let event = events.first else { return }
        #expect(event.eventType == "dose_quantity_updated")
        #expect(event.previousCount == 2)
        #expect(event.newCount == 0)
        #expect(event.quantityChange == -2) // clamped, NOT -4
    }

    @Test func updateDose_skippedStatus_quantityChange_recordsNoInventoryEvent() throws {
        let db = try MedTrackerDatabase.open()
        try db.write { d in
            try makeMedication(inventoryCount: 2).insert(d)
            try makeDose(quantity: 1, status: "skipped").insert(d)
        }

        let repo = DoseRepository(dbWriter: db)
        _ = try repo.updateDose(userId: "user_1", doseId: "dose_1", quantity: 3)

        let med = try db.read { d in try Medication.filter(key: "med_1").fetchOne(d) }
        #expect(med?.inventoryCount == 2)
        #expect(try db.read { d in try InventoryEvent.fetchCount(d) } == 0)
    }

    @Test func updateDose_takenStatus_quantityUnchanged_recordsNoInventoryEventButAuditsOtherChanges() throws {
        let db = try MedTrackerDatabase.open()
        try db.write { d in
            try makeMedication(inventoryCount: 2).insert(d)
            try makeDose(quantity: 3, status: "taken").insert(d)
        }

        let repo = DoseRepository(dbWriter: db)
        _ = try repo.updateDose(userId: "user_1", doseId: "dose_1", quantity: 3, notes: .some("edited note"))

        #expect(try db.read { d in try InventoryEvent.fetchCount(d) } == 0)
        let dose = try db.read { d in try DoseLog.filter(key: "dose_1").fetchOne(d) }
        #expect(dose?.notes == "edited note")
        #expect(try db.read { d in try AuditLog.fetchCount(d) } == 1) // notes changed -> audit fired
    }

    @Test func updateDose_noActualChanges_writesNoAuditRow() throws {
        let db = try MedTrackerDatabase.open()
        try db.write { d in
            try makeMedication(inventoryCount: 2).insert(d)
            try makeDose(quantity: 3, status: "taken").insert(d)
        }

        let repo = DoseRepository(dbWriter: db)
        _ = try repo.updateDose(userId: "user_1", doseId: "dose_1", quantity: 3) // identical value

        #expect(try db.read { d in try AuditLog.fetchCount(d) } == 0)
        #expect(try db.read { d in try InventoryEvent.fetchCount(d) } == 0)
    }

    @Test func updateDose_returnsNilWhenDoseDoesNotExist() throws {
        let db = try MedTrackerDatabase.open()
        let repo = DoseRepository(dbWriter: db)
        let result = try repo.updateDose(userId: "user_1", doseId: "missing", quantity: 5)
        #expect(result == nil)
    }

    // MARK: - InventoryRepository.refillMedication

    @Test func refillMedication_seedsAnUntrackedMedication() throws {
        let db = try MedTrackerDatabase.open()
        try db.write { d in try makeMedication(inventoryCount: nil).insert(d) }

        let repo = InventoryRepository(dbWriter: db)
        let result = try repo.refillMedication(userId: "user_1", medicationId: "med_1", quantity: 30)
        #expect(result == InventoryRepository.RefillResult(previousCount: nil, newCount: 30))

        let med = try db.read { d in try Medication.filter(key: "med_1").fetchOne(d) }
        #expect(med?.inventoryCount == 30)

        let events = try db.read { d in try InventoryEvent.fetchAll(d) }
        #expect(events.count == 1)
        guard let event = events.first else { return }
        #expect(event.eventType == "refill")
        #expect(event.previousCount == nil)
        #expect(event.newCount == 30)
        #expect(event.quantityChange == 30)
    }

    @Test func refillMedication_rejectsNonPositiveQuantity() throws {
        let db = try MedTrackerDatabase.open()
        try db.write { d in try makeMedication(inventoryCount: 5).insert(d) }
        let repo = InventoryRepository(dbWriter: db)

        expectThrows(InventoryRepositoryError.invalidRefillQuantity) {
            try repo.refillMedication(userId: "user_1", medicationId: "med_1", quantity: 0)
        }
        expectThrows(InventoryRepositoryError.invalidRefillQuantity) {
            try repo.refillMedication(userId: "user_1", medicationId: "med_1", quantity: -3)
        }
        #expect(try db.read { d in try InventoryEvent.fetchCount(d) } == 0)
        let med = try db.read { d in try Medication.filter(key: "med_1").fetchOne(d) }
        #expect(med?.inventoryCount == 5) // untouched
    }

    @Test func refillMedication_throwsForUnknownMedication() throws {
        let db = try MedTrackerDatabase.open()
        let repo = InventoryRepository(dbWriter: db)
        expectThrows(InventoryRepositoryError.medicationNotFound) {
            try repo.refillMedication(userId: "user_1", medicationId: "missing", quantity: 5)
        }
    }

    // MARK: - InventoryRepository.adjustInventory

    @Test func adjustInventory_rejectsZeroChange() throws {
        let db = try MedTrackerDatabase.open()
        try db.write { d in try makeMedication(inventoryCount: 12).insert(d) }
        let repo = InventoryRepository(dbWriter: db)

        expectThrows(InventoryRepositoryError.invalidAdjustment) {
            try repo.adjustInventory(userId: "user_1", medicationId: "med_1", newCount: 12)
        }
        #expect(try db.read { d in try InventoryEvent.fetchCount(d) } == 0)
    }

    @Test func adjustInventory_rejectsNegativeNewCount() throws {
        let db = try MedTrackerDatabase.open()
        try db.write { d in try makeMedication(inventoryCount: 5).insert(d) }
        let repo = InventoryRepository(dbWriter: db)

        expectThrows(InventoryRepositoryError.invalidAdjustment) {
            try repo.adjustInventory(userId: "user_1", medicationId: "med_1", newCount: -1)
        }
        #expect(try db.read { d in try InventoryEvent.fetchCount(d) } == 0)
    }

    @Test func adjustInventory_recordsSignedNegativeDeltaOnDecrease() throws {
        let db = try MedTrackerDatabase.open()
        try db.write { d in try makeMedication(inventoryCount: 30).insert(d) }
        let repo = InventoryRepository(dbWriter: db)

        let result = try repo.adjustInventory(userId: "user_1", medicationId: "med_1", newCount: 26, note: "spilled 4 pills")
        #expect(result == InventoryRepository.AdjustResult(previousCount: 30, newCount: 26, quantityChange: -4))

        let events = try db.read { d in try InventoryEvent.fetchAll(d) }
        #expect(events.count == 1)
        guard let event = events.first else { return }
        #expect(event.eventType == "manual_adjustment")
        #expect(event.quantityChange == -4)
        #expect(event.note == "spilled 4 pills")
    }

    @Test func adjustInventory_recordsSignedPositiveDeltaOnIncrease() throws {
        let db = try MedTrackerDatabase.open()
        try db.write { d in try makeMedication(inventoryCount: 5).insert(d) }
        let repo = InventoryRepository(dbWriter: db)

        let result = try repo.adjustInventory(userId: "user_1", medicationId: "med_1", newCount: 12)
        #expect(result.quantityChange == 7)
        let events = try db.read { d in try InventoryEvent.fetchAll(d) }
        #expect(events.first?.quantityChange == 7)
        #expect(events.first?.note == nil)
    }

    @Test func adjustInventory_treatsNilPreviousCountAsZero() throws {
        let db = try MedTrackerDatabase.open()
        try db.write { d in try makeMedication(inventoryCount: nil).insert(d) }
        let repo = InventoryRepository(dbWriter: db)

        let result = try repo.adjustInventory(userId: "user_1", medicationId: "med_1", newCount: 30)
        #expect(result == InventoryRepository.AdjustResult(previousCount: nil, newCount: 30, quantityChange: 30))
    }

    // MARK: - MedicationRepository

    @Test func createMedicationWithSchedules_insertsMedicationSchedulesAndAuditTogether() throws {
        let db = try MedTrackerDatabase.open()
        let repo = MedicationRepository(dbWriter: db)
        let fields = MedicationFields(
            name: "Aspirin", dosageAmount: "100", dosageUnit: "mg",
            form: "tablet", category: "otc", colour: "#111111"
        )
        let schedules = [MedicationScheduleInput(scheduleKind: "interval", intervalHours: "8", effectiveFrom: now)]

        let med = try repo.createMedicationWithSchedules(userId: "user_1", fields: fields, schedules: schedules)

        let scheduleCount = try db.read { d in
            try MedicationSchedule.filter(Column("medication_id") == med.id).fetchCount(d)
        }
        #expect(scheduleCount == 1)
        #expect(try db.read { d in try Medication.fetchCount(d) } == 1)
        #expect(try db.read { d in try AuditLog.fetchCount(d) } == 1)
    }

    @Test func updateMedicationWithSchedules_replacesScheduleSetAndAuditsOnlyIfChanged() throws {
        let db = try MedTrackerDatabase.open()
        let repo = MedicationRepository(dbWriter: db)
        let fields = MedicationFields(
            name: "Aspirin", dosageAmount: "100", dosageUnit: "mg",
            form: "tablet", category: "otc", colour: "#111111"
        )
        let med = try repo.createMedicationWithSchedules(
            userId: "user_1",
            fields: fields,
            schedules: [MedicationScheduleInput(scheduleKind: "interval", intervalHours: "8", effectiveFrom: now)]
        )

        var updatedFields = fields
        updatedFields.name = "Aspirin (updated)"
        let newSchedules = [
            MedicationScheduleInput(scheduleKind: "fixed_time", timeOfDay: "08:00", effectiveFrom: now),
            MedicationScheduleInput(scheduleKind: "fixed_time", timeOfDay: "20:00", effectiveFrom: now),
        ]

        let updated = try repo.updateMedicationWithSchedules(
            userId: "user_1", medicationId: med.id, fields: updatedFields, schedules: newSchedules
        )
        #expect(updated?.name == "Aspirin (updated)")

        let scheduleRows = try db.read { d in
            try MedicationSchedule.filter(Column("medication_id") == med.id).fetchAll(d)
        }
        #expect(scheduleRows.count == 2)
        #expect(scheduleRows.allSatisfy { $0.scheduleKind == "fixed_time" })

        // One "create" audit row from the initial insert, one "update" row from this call.
        #expect(try db.read { d in try AuditLog.fetchCount(d) } == 2)

        // A second update with identical fields (but the same schedules again, which is
        // still a full delete-then-insert of an equal set) writes no additional audit row.
        _ = try repo.updateMedicationWithSchedules(
            userId: "user_1", medicationId: med.id, fields: updatedFields, schedules: newSchedules
        )
        #expect(try db.read { d in try AuditLog.fetchCount(d) } == 2)
    }

    @Test func updateMedicationWithSchedules_returnsNilWhenMedicationDoesNotExist() throws {
        let db = try MedTrackerDatabase.open()
        let repo = MedicationRepository(dbWriter: db)
        let fields = MedicationFields(name: "X", dosageAmount: "1", dosageUnit: "mg", form: "tablet", category: "otc", colour: "#111111")
        let result = try repo.updateMedicationWithSchedules(userId: "user_1", medicationId: "missing", fields: fields, schedules: [])
        #expect(result == nil)
    }

    @Test func archiveMedication_setsFlagsAndWritesAuditRow() throws {
        let db = try MedTrackerDatabase.open()
        try db.write { d in try makeMedication().insert(d) }
        let repo = MedicationRepository(dbWriter: db)

        let ok = try repo.archiveMedication(userId: "user_1", medicationId: "med_1")
        #expect(ok == true)

        let med = try db.read { d in try Medication.filter(key: "med_1").fetchOne(d) }
        #expect(med?.isArchived == true)
        #expect(med?.archivedAt != nil)
        #expect(try db.read { d in try AuditLog.fetchCount(d) } == 1)
    }

    @Test func unarchiveMedication_clearsFlagsAndWritesAuditRow() throws {
        let db = try MedTrackerDatabase.open()
        try db.write { d in
            var med = makeMedication()
            med.isArchived = true
            med.archivedAt = nowEpoch
            try med.insert(d)
        }
        let repo = MedicationRepository(dbWriter: db)

        let ok = try repo.unarchiveMedication(userId: "user_1", medicationId: "med_1")
        #expect(ok == true)

        let med = try db.read { d in try Medication.filter(key: "med_1").fetchOne(d) }
        #expect(med?.isArchived == false)
        #expect(med?.archivedAt == nil)
        #expect(try db.read { d in try AuditLog.fetchCount(d) } == 1)
    }

    @Test func archiveMedication_returnsFalseWhenMedicationDoesNotExist() throws {
        let db = try MedTrackerDatabase.open()
        let repo = MedicationRepository(dbWriter: db)
        let ok = try repo.archiveMedication(userId: "user_1", medicationId: "missing")
        #expect(ok == false)
        #expect(try db.read { d in try AuditLog.fetchCount(d) } == 0)
    }

    // MARK: - Atomic rollback ("retires the web's best-effort-atomic caveat")

    @Test func logDose_rollsBackEverythingOnMidTransactionFailure() throws {
        let db = try MedTrackerDatabase.open()
        try db.write { d in try makeMedication(inventoryCount: 10).insert(d) }

        var repo = DoseRepository(dbWriter: db)
        repo.testFaultAfterMutation = { throw InjectedFailure() }

        #expect(throws: InjectedFailure.self) {
            try repo.logDose(userId: "user_1", medicationId: "med_1", quantity: 3)
        }

        // Nothing committed, even though the dose insert + inventory decrement +
        // event insert + audit insert all happened before the injected throw.
        #expect(try db.read { d in try DoseLog.fetchCount(d) } == 0)
        let med = try db.read { d in try Medication.filter(key: "med_1").fetchOne(d) }
        #expect(med?.inventoryCount == 10)
        #expect(try db.read { d in try InventoryEvent.fetchCount(d) } == 0)
        #expect(try db.read { d in try AuditLog.fetchCount(d) } == 0)
    }

    @Test func deleteDose_rollsBackEverythingOnMidTransactionFailure() throws {
        let db = try MedTrackerDatabase.open()
        try db.write { d in
            try makeMedication(inventoryCount: 5).insert(d)
            try makeDose(quantity: 10, status: "taken").insert(d)
        }

        var repo = DoseRepository(dbWriter: db)
        repo.testFaultAfterMutation = { throw InjectedFailure() }

        #expect(throws: InjectedFailure.self) {
            try repo.deleteDose(userId: "user_1", doseId: "dose_1")
        }

        // The dose delete + inventory restore + event insert + audit insert all
        // happened before the injected throw — none of it should be durable.
        #expect(try db.read { d in try DoseLog.fetchCount(d) } == 1)
        let med = try db.read { d in try Medication.filter(key: "med_1").fetchOne(d) }
        #expect(med?.inventoryCount == 5)
        #expect(try db.read { d in try InventoryEvent.fetchCount(d) } == 0)
        #expect(try db.read { d in try AuditLog.fetchCount(d) } == 0)
    }

    @Test func refillMedication_rollsBackEverythingOnMidTransactionFailure() throws {
        let db = try MedTrackerDatabase.open()
        try db.write { d in try makeMedication(inventoryCount: 5).insert(d) }

        var repo = InventoryRepository(dbWriter: db)
        repo.testFaultAfterMutation = { throw InjectedFailure() }

        #expect(throws: InjectedFailure.self) {
            try repo.refillMedication(userId: "user_1", medicationId: "med_1", quantity: 20)
        }

        let med = try db.read { d in try Medication.filter(key: "med_1").fetchOne(d) }
        #expect(med?.inventoryCount == 5)
        #expect(try db.read { d in try InventoryEvent.fetchCount(d) } == 0)
    }

    @Test func adjustInventory_rollsBackEverythingOnMidTransactionFailure() throws {
        let db = try MedTrackerDatabase.open()
        try db.write { d in try makeMedication(inventoryCount: 30).insert(d) }

        var repo = InventoryRepository(dbWriter: db)
        repo.testFaultAfterMutation = { throw InjectedFailure() }

        #expect(throws: InjectedFailure.self) {
            try repo.adjustInventory(userId: "user_1", medicationId: "med_1", newCount: 10)
        }

        let med = try db.read { d in try Medication.filter(key: "med_1").fetchOne(d) }
        #expect(med?.inventoryCount == 30)
        #expect(try db.read { d in try InventoryEvent.fetchCount(d) } == 0)
    }

    /// Uses a REAL SQLite constraint violation (the 3-way discriminated-union
    /// `CHECK` on `medication_schedule` from Task 13) rather than the
    /// injected-fault hook, proving genuine transactional rollback: the
    /// medication update and the delete-then-insert schedule replacement
    /// both roll back together when one replacement schedule row is invalid.
    @Test func updateMedicationWithSchedules_rollsBackOnScheduleCheckConstraintViolation() throws {
        let db = try MedTrackerDatabase.open()
        let repo = MedicationRepository(dbWriter: db)
        let fields = MedicationFields(
            name: "Aspirin", dosageAmount: "100", dosageUnit: "mg",
            form: "tablet", category: "otc", colour: "#111111"
        )
        let med = try repo.createMedicationWithSchedules(
            userId: "user_1",
            fields: fields,
            schedules: [MedicationScheduleInput(scheduleKind: "interval", intervalHours: "8", effectiveFrom: now)]
        )

        var badFields = fields
        badFields.name = "Should not stick"
        // Invalid: "interval" kind with BOTH interval_hours and time_of_day set.
        let badSchedules = [
            MedicationScheduleInput(scheduleKind: "interval", timeOfDay: "08:00", intervalHours: "8", effectiveFrom: now),
        ]

        #expect(throws: (any Error).self) {
            try repo.updateMedicationWithSchedules(
                userId: "user_1", medicationId: med.id, fields: badFields, schedules: badSchedules
            )
        }

        // Medication row unchanged, original schedule row intact, no bad
        // schedule row persisted, no audit row for the failed update.
        let reread = try db.read { d in try Medication.filter(key: med.id).fetchOne(d) }
        #expect(reread?.name == "Aspirin")

        let scheduleRows = try db.read { d in
            try MedicationSchedule.filter(Column("medication_id") == med.id).fetchAll(d)
        }
        #expect(scheduleRows.count == 1)
        #expect(scheduleRows.first?.scheduleKind == "interval")
        #expect(scheduleRows.first?.intervalHours == "8")

        #expect(try db.read { d in try AuditLog.fetchCount(d) } == 1) // only the original "create"
    }
}
