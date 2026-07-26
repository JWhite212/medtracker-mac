import Foundation
import GRDB
import MedTrackerData
@testable import MedTrackerSync
import MedTrackerTestSupport
import Testing

private func openDB() throws -> DatabaseQueue {
    try MedTrackerDatabase.open()
}

@Test func deltaUpsertsMedicationScheduleDose() throws {
    let db = try openDB()
    let r = try JSONDecoder().decode(SyncResponse.self, from: Data(Fixtures.syncDelta.utf8))
    try SyncApplier(dbWriter: db).apply(r)
    try db.read { d in
        try #expect(Medication.fetchCount(d) == 1)
        try #expect(MedicationSchedule.fetchCount(d) == 1)
        try #expect(DoseLog.fetchOne(d, key: "d1")?.status == "taken")
    }
}

@Test func deltaReplacesSchedulesWholesale() throws {
    let db = try openDB()
    // seed a med with TWO local schedules
    try db.write { d in
        try Medication(id: "m1", userId: "u1", name: "Med", dosageAmount: "50", dosageUnit: "mg",
                       form: "tablet", category: "prescription", colour: "#112233", startedAt: 0,
                       createdAt: 0, updatedAt: 0).insert(d)
        try MedicationSchedule(id: "old1", medicationId: "m1", userId: "u1", scheduleKind: "prn",
                               effectiveFrom: 0, createdAt: 0).insert(d)
        try MedicationSchedule(id: "old2", medicationId: "m1", userId: "u1", scheduleKind: "prn",
                               effectiveFrom: 0, createdAt: 0).insert(d)
    }
    let r = try JSONDecoder().decode(SyncResponse.self, from: Data(Fixtures.syncDelta.utf8))
    try SyncApplier(dbWriter: db).apply(r) // response carries exactly one schedule s1 for m1
    try db.read { d in
        let ids = try MedicationSchedule.filter(Column("medication_id") == "m1")
            .fetchAll(d).map(\.id).sorted()
        #expect(ids == ["s1"]) // old1/old2 gone, s1 present
    }
}

@Test func deltaAppliesTombstoneDeletion() throws {
    let db = try openDB()
    try db.write { d in
        try Medication(id: "m1", userId: "u1", name: "M", dosageAmount: "1", dosageUnit: "mg",
                       form: "tablet", category: "otc", colour: "#000000", startedAt: 0, createdAt: 0,
                       updatedAt: 0).insert(d)
        try DoseLog(id: "dOld", userId: "u1", medicationId: "m1", takenAt: 0, loggedAt: 0,
                    updatedAt: 0).insert(d)
    }
    let r = try JSONDecoder().decode(SyncResponse.self, from: Data(Fixtures.syncDelta.utf8))
    try SyncApplier(dbWriter: db).apply(r) // tombstone t1 deletes dose_log dOld
    try db.read { d in try #expect(DoseLog.fetchOne(d, key: "dOld") == nil) }
}
