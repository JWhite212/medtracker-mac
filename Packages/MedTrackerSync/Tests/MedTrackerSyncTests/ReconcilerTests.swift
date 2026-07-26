import Foundation
import GRDB
import MedTrackerData
@testable import MedTrackerSync
import Testing

private func writeDeferred(_ db: DatabaseQueue, _ work: @escaping (Database) throws -> Void) throws {
    try db.write { d in try d.execute(sql: "PRAGMA defer_foreign_keys = ON"); try work(d) }
}

@Test func reconcilesDoseId() throws {
    let db = try MedTrackerDatabase.open()
    try db.write { d in
        try Medication(id: "m1", userId: "u1", name: "M", dosageAmount: "1", dosageUnit: "mg",
                       form: "tablet", category: "otc", colour: "#000000", startedAt: 0, createdAt: 0,
                       updatedAt: 0).insert(d)
        try DoseLog(id: "localDose", userId: "u1", medicationId: "m1", takenAt: 0, loggedAt: 0,
                    updatedAt: 0).insert(d)
    }
    try writeDeferred(db) { d in
        try Reconciler().reconcile(localId: "localDose", serverId: "srvDose", kind: .doseLog, in: d)
    }
    try db.read { d in
        try #expect(DoseLog.fetchOne(d, key: "localDose") == nil)
        try #expect(DoseLog.fetchOne(d, key: "srvDose") != nil)
    }
}

@Test func reconcilesMedicationAndCascadesChildrenAndPendingPayloads() throws {
    let db = try MedTrackerDatabase.open()
    let outbox = OutboxStore(dbWriter: db)
    try db.write { d in
        try Medication(id: "localMed", userId: "u1", name: "M", dosageAmount: "1", dosageUnit: "mg",
                       form: "tablet", category: "otc", colour: "#000000", startedAt: 0, createdAt: 0,
                       updatedAt: 0).insert(d)
        try MedicationSchedule(id: "sc1", medicationId: "localMed", userId: "u1",
                               scheduleKind: "prn", effectiveFrom: 0, createdAt: 0).insert(d)
        try DoseLog(id: "do1", userId: "u1", medicationId: "localMed", takenAt: 0, loggedAt: 0,
                    updatedAt: 0).insert(d)
    }
    // a pending command that references the still-local medication id
    let pendingCmd = try outbox.enqueue(type: "log_dose",
                                        payload: .object(["medicationId": .string("localMed")]))
    try writeDeferred(db) { d in
        try Reconciler().reconcile(localId: "localMed", serverId: "srvMed", kind: .medication, in: d)
    }
    try db.read { d in
        try #expect(Medication.fetchOne(d, key: "srvMed") != nil)
        try #expect(Medication.fetchOne(d, key: "localMed") == nil)
        try #expect(MedicationSchedule.fetchOne(d, key: "sc1")?.medicationId == "srvMed")
        try #expect(DoseLog.fetchOne(d, key: "do1")?.medicationId == "srvMed")
        let cmd = try OutboxEntry.fetchOne(d, key: pendingCmd.id)!
        #expect(cmd.payload.contains("srvMed")); #expect(!cmd.payload.contains("localMed"))
    }
}
