import Foundation
import GRDB
@testable import MedTrackerApp
import MedTrackerCore
import MedTrackerData
import MedTrackerSync
import Testing

@MainActor
private func fixture() throws -> (DatabaseQueue, WriteCoordinator) {
    let db = try MedTrackerDatabase.open() // in-memory (path: nil)
    let coord = WriteCoordinator(dbWriter: db, outbox: OutboxStore(dbWriter: db), userId: "u1")
    return (db, coord)
}

@MainActor
private func seedMed(_ db: DatabaseQueue, id: String = "m1", inventory: Int? = 30, sortOrder: Int = 0) throws {
    try db.write { d in
        try Medication(id: id, userId: "u1", name: "Med", dosageAmount: "50", dosageUnit: "mg",
                       form: "tablet", category: "prescription", colour: "#112233",
                       inventoryCount: inventory, sortOrder: sortOrder,
                       startedAt: 0, createdAt: 0, updatedAt: 0).insert(d)
    }
}

private func outboxRows(_ db: DatabaseQueue, type: String) throws -> [OutboxEntry] {
    try db.read { try OutboxEntry.filter(Column("command_type") == type).fetchAll($0) }
}

private func payloadJSON(_ e: OutboxEntry) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(e.payload.utf8))
}

@MainActor @Test func logDoseInsertsDoseClampsInventoryEnqueuesLogDose() async throws {
    let (db, coord) = try fixture()
    try seedMed(db, inventory: 3)
    try await coord.logDose(medicationId: "m1", quantity: 2, takenAt: nil, notes: "hi", sideEffects: nil)

    try await db.read { d in
        try #expect(DoseLog.fetchCount(d) == 1)
        let dose = try DoseLog.fetchAll(d).first
        #expect(dose?.status == "taken")
        #expect(dose?.quantity == 2)
        try #expect(Medication.fetchOne(d, key: "m1")?.inventoryCount == 1) // 3 - 2, clamped
        // state-only: never write server-owned ledger rows
        try #expect(InventoryEvent.fetchCount(d) == 0)
        try #expect(AuditLog.fetchCount(d) == 0)
    }
    let rows = try outboxRows(db, type: "log_dose")
    #expect(rows.count == 1)
    #expect(rows[0].localEntityKind == "dose_log")
    #expect(rows[0].localEntityId != nil)
    let p = try payloadJSON(rows[0])
    #expect(p["medicationId"]?.stringValue == "m1")
    #expect(rows[0].payload.contains("\"quantity\":2")) // integer renders whole, not 2.0
    #expect(p["notes"]?.stringValue == "hi")
}

@MainActor @Test func logDoseRejectsOutOfRangeQuantity() async throws {
    let (db, coord) = try fixture()
    try seedMed(db)
    await #expect(throws: WriteError.invalidQuantity) {
        try await coord.logDose(medicationId: "m1", quantity: 11, takenAt: nil, notes: nil, sideEffects: nil)
    }
    try await db.read { try #expect(DoseLog.fetchCount($0) == 0) }
    #expect(try outboxRows(db, type: "log_dose").isEmpty)
}

@MainActor @Test func skipDoseInsertsSkippedNoInventoryChange() async throws {
    let (db, coord) = try fixture()
    try seedMed(db, inventory: 5)
    try await coord.skipDose(medicationId: "m1", slotExpectedTime: Date(timeIntervalSince1970: 1000))
    try await db.read { d in
        let dose = try DoseLog.fetchAll(d).first
        #expect(dose?.status == "skipped")
        #expect(dose?.quantity == 1)
        #expect(dose?.takenAt == 1000)
        try #expect(Medication.fetchOne(d, key: "m1")?.inventoryCount == 5) // unchanged
    }
    let rows = try outboxRows(db, type: "skip_dose")
    #expect(rows.count == 1)
    #expect(rows[0].localEntityKind == "dose_log")
    #expect(try payloadJSON(rows[0])["medicationId"]?.stringValue == "m1")
}

@MainActor @Test func editDoseDoubleOptionalClearsAndOmits() async throws {
    let (db, coord) = try fixture()
    try seedMed(db, inventory: 10)
    try await db.write { d in
        try DoseLog(id: "d1", userId: "u1", medicationId: "m1", quantity: 2, takenAt: 0, loggedAt: 0,
                    notes: "old", sideEffects: [SideEffectEntry(name: "nausea", severity: "mild")],
                    status: "taken", updatedAt: 0).insert(d)
    }
    // clear sideEffects (.some(nil)); leave notes untouched (.none); bump qty 2 -> 4
    try await coord.editDose(doseId: "d1", takenAt: nil, quantity: 4, notes: .none, sideEffects: .some(nil))
    try await db.read { d in
        let dose = try DoseLog.fetchOne(d, key: "d1")
        #expect(dose?.quantity == 4)
        #expect(dose?.sideEffectsArray == nil) // cleared
        #expect(dose?.notes == "old") // untouched
        try #expect(Medication.fetchOne(d, key: "m1")?.inventoryCount == 8) // 10 - (4-2)
    }
    let p = try payloadJSON(try outboxRows(db, type: "edit_dose")[0])
    #expect(p["doseId"]?.stringValue == "d1")
    #expect(p["sideEffects"] == JSONValue.null) // explicit null clears
    #expect(p["notes"] == nil) // omitted (undefined) leaves untouched
}

@MainActor @Test func deleteDoseRestoresInventoryUnclamped() async throws {
    let (db, coord) = try fixture()
    try seedMed(db, inventory: 1)
    try await db.write { d in
        try DoseLog(id: "d1", userId: "u1", medicationId: "m1", quantity: 3, takenAt: 0, loggedAt: 0,
                    status: "taken", updatedAt: 0).insert(d)
    }
    try await coord.deleteDose(doseId: "d1")
    try await db.read { d in
        try #expect(DoseLog.fetchOne(d, key: "d1") == nil)
        try #expect(Medication.fetchOne(d, key: "m1")?.inventoryCount == 4) // 1 + 3, unclamped
    }
    #expect(try payloadJSON(try outboxRows(db, type: "delete_dose")[0])["doseId"]?.stringValue == "d1")
}

@MainActor @Test func refillAddsToInventory() async throws {
    let (db, coord) = try fixture()
    try seedMed(db, inventory: nil)
    try await coord.refill(medicationId: "m1", amount: 20, note: "pharmacy")
    try await db.read { try #expect(Medication.fetchOne($0, key: "m1")?.inventoryCount == 20) } // (nil ?? 0) + 20
    let p = try payloadJSON(try outboxRows(db, type: "refill")[0])
    #expect(p["medicationId"]?.stringValue == "m1")
    #expect(try outboxRows(db, type: "refill")[0].payload.contains("\"quantity\":20"))
    #expect(p["note"]?.stringValue == "pharmacy")
}

@MainActor @Test func refillRejectsNonPositive() async throws {
    let (db, coord) = try fixture()
    try seedMed(db)
    await #expect(throws: WriteError.invalidRefillQuantity) {
        try await coord.refill(medicationId: "m1", amount: 0, note: nil)
    }
}

@MainActor @Test func adjustInventorySetsAbsoluteAndRejectsNoOp() async throws {
    let (db, coord) = try fixture()
    try seedMed(db, inventory: 10)
    try await coord.adjustInventory(medicationId: "m1", newCount: 42, note: nil)
    try await db.read { try #expect(Medication.fetchOne($0, key: "m1")?.inventoryCount == 42) }
    await #expect(throws: WriteError.invalidAdjustment) { // equal to current -> no-op rejected
        try await coord.adjustInventory(medicationId: "m1", newCount: 42, note: nil)
    }
    #expect(try outboxRows(db, type: "adjust_inventory").count == 1)
}

@MainActor @Test func upsertCreateReconcilesMedicationEnvelope() async throws {
    let (db, coord) = try fixture()
    let fields = MedicationFields(name: "New", dosageAmount: "5", dosageUnit: "mg",
                                  form: "tablet", category: "otc", colour: "#abcdef")
    let schedules = [MedicationScheduleInput(scheduleKind: "interval", intervalHours: "8",
                                             sortOrder: 0, effectiveFrom: Date(timeIntervalSince1970: 0))]
    let medId = try await coord.upsertMedication(id: nil, fields: fields, schedules: schedules)
    try await db.read { d in
        try #expect(Medication.fetchOne(d, key: medId) != nil)
        try #expect(MedicationSchedule.filter(Column("medication_id") == medId).fetchCount(d) == 1)
        try #expect(AuditLog.fetchCount(d) == 0) // state-only, no audit
    }
    let e = try outboxRows(db, type: "upsert_medication_with_schedules")[0]
    #expect(e.localEntityId == medId) // create reconciles .medication
    #expect(e.localEntityKind == "medication")
    let p = try payloadJSON(e)
    #expect(p["id"] == nil) // create omits id
    #expect(p["medication"]?["name"]?.stringValue == "New")
    #expect(e.payload.contains("\"intervalHours\":8")) // schedule interval is a number on the wire
}

@MainActor @Test func upsertFailureRollsBackStateAndOutboxTogether() async throws {
    let (db, coord) = try fixture()
    let fields = MedicationFields(name: "Bad", dosageAmount: "5", dosageUnit: "mg",
                                  form: "tablet", category: "otc", colour: "#abcdef")
    // interval kind with no intervalHours trips the 3-way CHECK inside the same txn
    let badSchedule = [MedicationScheduleInput(scheduleKind: "interval", intervalHours: nil,
                                               sortOrder: 0, effectiveFrom: Date(timeIntervalSince1970: 0))]
    await #expect(throws: (any Error).self) {
        _ = try await coord.upsertMedication(id: nil, fields: fields, schedules: badSchedule)
    }
    try await db.read { d in
        try #expect(Medication.fetchCount(d) == 0) // state effect rolled back …
        try #expect(OutboxEntry.fetchCount(d) == 0) // … together with the enqueue (§4.2 atomicity)
    }
}

@MainActor @Test func archiveAndUnarchiveFlipStateNoAudit() async throws {
    let (db, coord) = try fixture()
    try seedMed(db)
    try await coord.archive(medicationId: "m1")
    try await db.read { d in
        let m = try Medication.fetchOne(d, key: "m1")
        #expect(m?.isArchived == true); #expect(m?.archivedAt != nil)
        try #expect(AuditLog.fetchCount(d) == 0)
    }
    try await coord.unarchive(medicationId: "m1")
    try await db.read { d in
        let m = try Medication.fetchOne(d, key: "m1")
        #expect(m?.isArchived == false); #expect(m?.archivedAt == nil)
    }
    #expect(try outboxRows(db, type: "archive").count == 1)
    #expect(try outboxRows(db, type: "unarchive").count == 1)
}

@MainActor @Test func reorderDecomposesIntoPairwiseSwaps() async throws {
    let (db, coord) = try fixture()
    try seedMed(db, id: "A", sortOrder: 0)
    try seedMed(db, id: "B", sortOrder: 1)
    try seedMed(db, id: "C", sortOrder: 2)
    try await coord.reorder(orderedMedicationIds: ["C", "A", "B"])
    let order = try await db.read { try Medication.fetchActive($0, userId: "u1").map(\.id) }
    #expect(order == ["C", "A", "B"])
    let swaps = try outboxRows(db, type: "reorder")
    #expect(swaps.count == 2) // (C,B) then (C,A)
    for s in swaps {
        #expect(s.localEntityId == nil)
    } // reorder never reconciles
}

/// Regression: an untracked medication (`inventoryCount == nil`) adjusted to 0 is
/// a no-op the SERVER rejects (`newCount - (previousCount ?? 0) == 0`). Comparing
/// `Int?` to `Int` let it through locally, parking a failed outbox row and a wrong
/// count that no delta pull could heal.
@MainActor @Test func adjustInventoryToZeroOnUntrackedMedicationIsRejected() async throws {
    let (db, coord) = try fixture()
    try seedMed(db, inventory: nil)

    await #expect(throws: WriteError.invalidAdjustment) {
        try await coord.adjustInventory(medicationId: "m1", newCount: 0, note: nil)
    }

    try await db.read { try #expect(Medication.fetchOne($0, key: "m1")?.inventoryCount == nil) }
    #expect(try outboxRows(db, type: "adjust_inventory").isEmpty)
}

/// The mirror case must still work: seeding an untracked medication to a real
/// count is a genuine change, not a no-op.
@MainActor @Test func adjustInventorySeedsUntrackedMedicationToNonZero() async throws {
    let (db, coord) = try fixture()
    try seedMed(db, inventory: nil)

    try await coord.adjustInventory(medicationId: "m1", newCount: 20, note: nil)

    try await db.read { try #expect(Medication.fetchOne($0, key: "m1")?.inventoryCount == 20) }
    #expect(try outboxRows(db, type: "adjust_inventory").count == 1)
}
