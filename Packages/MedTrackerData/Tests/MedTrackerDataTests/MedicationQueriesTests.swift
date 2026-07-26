import Foundation
import GRDB
@testable import MedTrackerData
import Testing

private let epoch = Date(timeIntervalSince1970: 1_700_000_000).timeIntervalSince1970

private func med(_ id: String, sortOrder: Int, archived: Bool = false, user: String = "u1") -> Medication {
    Medication(id: id, userId: user, name: id, dosageAmount: "1", dosageUnit: "mg",
               form: "tablet", category: "otc", colour: "#000000",
               sortOrder: sortOrder, isArchived: archived,
               startedAt: epoch, createdAt: epoch, updatedAt: epoch)
}

struct MedicationQueriesTests {
    @Test func fetchActive_excludesArchived_ordersBySortOrder() throws {
        let db = try MedTrackerDatabase.open()
        try db.write { d in
            try med("b", sortOrder: 2).insert(d)
            try med("a", sortOrder: 1).insert(d)
            try med("z", sortOrder: 0, archived: true).insert(d)
            try med("other", sortOrder: 0, user: "u2").insert(d)  // different owner
        }
        let active = try db.read { try Medication.fetchActive($0, userId: "u1") }
        try #expect(active.map(\.id) == ["a", "b"])
        let archived = try db.read { try Medication.fetchArchived($0, userId: "u1") }
        try #expect(archived.map(\.id) == ["z"])
    }

    @Test func groupedByMedication_bucketsSchedulesPerMed() throws {
        let db = try MedTrackerDatabase.open()
        try db.write { d in
            try med("m1", sortOrder: 0).insert(d)
            try med("m2", sortOrder: 1).insert(d)
            try MedicationSchedule(id: "s1", medicationId: "m1", userId: "u1",
                                   scheduleKind: "prn", effectiveFrom: epoch, createdAt: epoch).insert(d)
            try MedicationSchedule(id: "s2", medicationId: "m1", userId: "u1",
                                   scheduleKind: "prn", effectiveFrom: epoch, createdAt: epoch).insert(d)
            try MedicationSchedule(id: "s3", medicationId: "m2", userId: "u1",
                                   scheduleKind: "prn", effectiveFrom: epoch, createdAt: epoch).insert(d)
        }
        let grouped = try db.read { try MedicationSchedule.groupedByMedication($0, userId: "u1") }
        try #expect(grouped["m1"]?.map(\.id).sorted() == ["s1", "s2"])
        try #expect(grouped["m2"]?.map(\.id) == ["s3"])
    }

    @Test func inventoryHistory_scopedToMed_orderedCreatedAtDesc() throws {
        let db = try MedTrackerDatabase.open()
        try db.write { d in
            try med("m1", sortOrder: 0).insert(d)
            try med("m2", sortOrder: 1).insert(d)
            try InventoryEvent(id: "e1", userId: "u1", medicationId: "m1",
                               eventType: "refill", quantityChange: 30, createdAt: epoch).insert(d)
            try InventoryEvent(id: "e2", userId: "u1", medicationId: "m1",
                               eventType: "dose_taken", quantityChange: -1, createdAt: epoch + 60).insert(d)
            try InventoryEvent(id: "e3", userId: "u1", medicationId: "m2",
                               eventType: "refill", quantityChange: 10, createdAt: epoch).insert(d)
        }
        let hist = try db.read { try InventoryEvent.history($0, userId: "u1", medicationId: "m1") }
        try #expect(hist.map(\.id) == ["e2", "e1"])   // newest first
    }
}
