import Foundation
import GRDB
@testable import MedTrackerData
import Testing

// Task 13: schema/migration/CHECK-constraint/localDate acceptance tests,
// against an in-memory GRDB database running the real `v1` migrator.

private let now = Date().timeIntervalSince1970

private func makeMedication(id: String = "med_1") -> Medication {
    Medication(
        id: id,
        userId: "user_1",
        name: "Ibuprofen",
        dosageAmount: "200",
        dosageUnit: "mg",
        form: "tablet",
        category: "otc",
        colour: "#ff0000",
        startedAt: now,
        createdAt: now,
        updatedAt: now
    )
}

struct SchemaTests {
    // MARK: - 1. Tables exist — valid rows insert cleanly

    @Test func insertsValidMedicationScheduleAndDoseLog() throws {
        let dbQueue = try MedTrackerDatabase.open()

        try dbQueue.write { db in
            try makeMedication().insert(db)

            let schedule = MedicationSchedule(
                id: "sched_1",
                medicationId: "med_1",
                userId: "user_1",
                scheduleKind: "interval",
                intervalHours: "8",
                effectiveFrom: now,
                createdAt: now
            )
            try schedule.insert(db)

            let dose = DoseLog(
                id: "dose_1",
                userId: "user_1",
                medicationId: "med_1",
                takenAt: now,
                loggedAt: now,
                updatedAt: now
            )
            try dose.insert(db)
        }

        let (medCount, scheduleCount, doseCount) = try dbQueue.read { db in
            (
                try Medication.fetchCount(db),
                try MedicationSchedule.fetchCount(db),
                try DoseLog.fetchCount(db)
            )
        }
        #expect(medCount == 1)
        #expect(scheduleCount == 1)
        #expect(doseCount == 1)
    }

    // MARK: - 2. CHECK constraint rejects invalid schedule rows

    @Test func checkConstraint_rejectsIntervalRowThatAlsoHasTimeOfDay() throws {
        let dbQueue = try MedTrackerDatabase.open()
        try dbQueue.write { db in try makeMedication().insert(db) }

        #expect(throws: (any Error).self) {
            try dbQueue.write { db in
                let invalid = MedicationSchedule(
                    id: "sched_bad",
                    medicationId: "med_1",
                    userId: "user_1",
                    scheduleKind: "interval",
                    timeOfDay: "08:00",
                    intervalHours: "8",
                    effectiveFrom: now,
                    createdAt: now
                )
                try invalid.insert(db)
            }
        }
    }

    @Test func checkConstraint_rejectsFixedTimeRowThatAlsoHasIntervalHours() throws {
        let dbQueue = try MedTrackerDatabase.open()
        try dbQueue.write { db in try makeMedication().insert(db) }

        #expect(throws: (any Error).self) {
            try dbQueue.write { db in
                let invalid = MedicationSchedule(
                    id: "sched_bad",
                    medicationId: "med_1",
                    userId: "user_1",
                    scheduleKind: "fixed_time",
                    timeOfDay: "08:00",
                    intervalHours: "8",
                    effectiveFrom: now,
                    createdAt: now
                )
                try invalid.insert(db)
            }
        }
    }

    @Test func checkConstraint_rejectsPrnRowWithEitherFieldSet() throws {
        let dbQueue = try MedTrackerDatabase.open()
        try dbQueue.write { db in try makeMedication().insert(db) }

        #expect(throws: (any Error).self) {
            try dbQueue.write { db in
                let invalid = MedicationSchedule(
                    id: "sched_bad",
                    medicationId: "med_1",
                    userId: "user_1",
                    scheduleKind: "prn",
                    intervalHours: "8",
                    effectiveFrom: now,
                    createdAt: now
                )
                try invalid.insert(db)
            }
        }
    }

    @Test func checkConstraint_acceptsAllThreeValidShapes() throws {
        let dbQueue = try MedTrackerDatabase.open()
        try dbQueue.write { db in try makeMedication().insert(db) }

        try dbQueue.write { db in
            try MedicationSchedule(
                id: "sched_interval", medicationId: "med_1", userId: "user_1",
                scheduleKind: "interval", intervalHours: "8",
                effectiveFrom: now, createdAt: now
            ).insert(db)

            try MedicationSchedule(
                id: "sched_fixed", medicationId: "med_1", userId: "user_1",
                scheduleKind: "fixed_time", timeOfDay: "08:00",
                effectiveFrom: now, createdAt: now
            ).insert(db)

            try MedicationSchedule(
                id: "sched_prn", medicationId: "med_1", userId: "user_1",
                scheduleKind: "prn",
                effectiveFrom: now, createdAt: now
            ).insert(db)
        }

        let count = try dbQueue.read { db in try MedicationSchedule.fetchCount(db) }
        #expect(count == 3)
    }

    // MARK: - 3. localDate SQL function — DST boundary

    @Test func localDate_resolvesCorrectLocalDateAcrossSpringForwardBoundary() throws {
        let dbQueue = try MedTrackerDatabase.open()

        // 2026-03-08 00:30 EST (America/New_York is still UTC-5 at this
        // instant — the spring-forward 02:00→03:00 jump hasn't happened
        // yet) is 2026-03-08T05:30:00Z.
        let epoch = ISO8601DateFormatter().date(from: "2026-03-08T05:30:00Z")!.timeIntervalSince1970

        let localDate = try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT localDate(?, ?)", arguments: [epoch, "America/New_York"])
        }
        #expect(localDate == "2026-03-08")
    }

    @Test func localDate_resolvesCorrectLocalDateJustAfterSpringForward() throws {
        let dbQueue = try MedTrackerDatabase.open()

        // 2026-03-08 03:30 EDT (just after the spring-forward jump,
        // now UTC-4) is 2026-03-08T07:30:00Z — still the same local date.
        let epoch = ISO8601DateFormatter().date(from: "2026-03-08T07:30:00Z")!.timeIntervalSince1970

        let localDate = try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT localDate(?, ?)", arguments: [epoch, "America/New_York"])
        }
        #expect(localDate == "2026-03-08")
    }

    // MARK: - 4. ON DELETE CASCADE

    @Test func deletingMedicationCascadesToSchedulesAndDoseLogs() throws {
        let dbQueue = try MedTrackerDatabase.open()

        try dbQueue.write { db in
            try makeMedication().insert(db)
            try MedicationSchedule(
                id: "sched_1", medicationId: "med_1", userId: "user_1",
                scheduleKind: "interval", intervalHours: "8",
                effectiveFrom: now, createdAt: now
            ).insert(db)
            try DoseLog(
                id: "dose_1", userId: "user_1", medicationId: "med_1",
                takenAt: now, loggedAt: now, updatedAt: now
            ).insert(db)
            try InventoryEvent(
                id: "event_1", userId: "user_1", medicationId: "med_1",
                eventType: "dose_taken", quantityChange: -1, createdAt: now
            ).insert(db)
            try ReminderEvent(
                id: "reminder_1", userId: "user_1", medicationId: "med_1",
                reminderType: "overdue", dedupeKey: "user_1:med_1:overdue:interval:sched_1:slot",
                slotAt: now, createdAt: now
            ).insert(db)
        }

        _ = try dbQueue.write { db in
            try Medication.deleteAll(db)
        }

        let (scheduleCount, doseCount, eventCount, reminderCount) = try dbQueue.read { db in
            (
                try MedicationSchedule.fetchCount(db),
                try DoseLog.fetchCount(db),
                try InventoryEvent.fetchCount(db),
                try ReminderEvent.fetchCount(db)
            )
        }
        #expect(scheduleCount == 0)
        #expect(doseCount == 0)
        #expect(eventCount == 0)
        #expect(reminderCount == 0)
    }
}
