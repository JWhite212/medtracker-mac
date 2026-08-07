import Foundation
@testable import MedTrackerApp
import MedTrackerCore
import MedTrackerData
import Testing

// MARK: doseStatus (pure String → enum, with the "everything else is taken" fallback)

@Test func doseStatusMapsKnownAndUnknownRaws() {
    #expect(RecordAdapters.doseStatus("taken") == .taken)
    #expect(RecordAdapters.doseStatus("skipped") == .skipped)
    #expect(RecordAdapters.doseStatus("missed") == .missed)
    #expect(RecordAdapters.doseStatus("garbage") == .taken) // unknown → .taken (§4.1 fallback)
    #expect(RecordAdapters.doseStatus("") == .taken)
}

// MARK: scheduleRow

@Test func scheduleRowMapsIntervalKind() {
    let s = MedicationSchedule(id: "s1", medicationId: "m1", userId: "u1", scheduleKind: "interval",
                               timeOfDay: nil, intervalHours: "8", daysOfWeek: nil,
                               sortOrder: 0, effectiveFrom: 0, createdAt: 0)
    let row = RecordAdapters.scheduleRow(s)
    #expect(row.kind == .interval)
    #expect(row.intervalHours == Decimal(string: "8"))
    #expect(row.timeOfDay == nil)
    #expect(row.daysOfWeek == nil)
}

@Test func scheduleRowMapsFixedTimeWithDays() {
    let s = MedicationSchedule(id: "s2", medicationId: "m1", userId: "u1", scheduleKind: "fixed_time",
                               timeOfDay: "08:00", intervalHours: nil, daysOfWeek: [1, 3, 5],
                               sortOrder: 0, effectiveFrom: 0, createdAt: 0)
    let row = RecordAdapters.scheduleRow(s)
    #expect(row.kind == .fixedTime)
    #expect(row.timeOfDay == "08:00")
    #expect(row.daysOfWeek == [1, 3, 5]) // via MedicationSchedule.daysOfWeekArray
    #expect(row.intervalHours == nil)
}

@Test func scheduleRowUnknownKindFallsBackToPRN() {
    let s = MedicationSchedule(id: "s3", medicationId: "m1", userId: "u1", scheduleKind: "weird",
                               timeOfDay: nil, intervalHours: nil, daysOfWeek: nil,
                               sortOrder: 0, effectiveFrom: 0, createdAt: 0)
    #expect(RecordAdapters.scheduleRow(s).kind == .prn) // rawValue? ?? .prn
}

// MARK: doseEvent (epoch Double → Date, status via doseStatus)

@Test func doseEventMapsEpochAndStatus() {
    let d = DoseLog(id: "d1", userId: "u1", medicationId: "m1", quantity: 2,
                    takenAt: 1_785_060_000, loggedAt: 1_785_060_000, notes: nil,
                    sideEffects: nil, status: "skipped", updatedAt: 0)
    let e = RecordAdapters.doseEvent(d)
    #expect(e.id == "d1")
    #expect(e.medicationId == "m1")
    #expect(e.takenAt == Date(timeIntervalSince1970: 1_785_060_000))
    #expect(e.status == .skipped)
}

// MARK: pattern

@Test func patternMapsKnownAndFallsBackToSolid() {
    func med(_ p: String) -> Medication {
        Medication(id: "m", userId: "u", name: "M", dosageAmount: "1", dosageUnit: "mg",
                   form: "tablet", category: "otc", colour: "#000000", pattern: p,
                   startedAt: 0, createdAt: 0, updatedAt: 0)
    }
    #expect(RecordAdapters.pattern(med("checkerboard")) == .checkerboard)
    #expect(RecordAdapters.pattern(med("h-stripes")) == .hStripes)
    #expect(RecordAdapters.pattern(med("not-a-pattern")) == .solid) // rawValue? ?? .solid
}
