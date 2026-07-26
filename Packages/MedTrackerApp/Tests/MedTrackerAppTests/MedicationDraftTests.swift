import Foundation
@testable import MedTrackerApp
import MedTrackerCore
import MedTrackerData
import Testing

@MainActor private func validNewDraft() -> MedicationDraft {
    let d = MedicationDraft(mode: .new)
    d.name = "Ibuprofen"; d.dosageAmount = "200"; d.dosageUnit = "mg"
    d.form = "tablet"; d.category = "otc"; d.colour = "#3366ff"
    d.scheduleRows = [MedicationDraft.ScheduleDraft(id: "r1", kind: "interval",
                                                    intervalHours: "8", timeOfDay: "", daysOfWeek: [])]
    return d
}

@Test @MainActor func validDraftProducesFieldsAndSchedules() {
    let d = validNewDraft()
    #expect(d.validate().isEmpty)
    let f = d.fields()
    #expect(f.name == "Ibuprofen"); #expect(f.dosageAmount == "200")
    #expect(f.scheduleType == "scheduled")
    let s = d.schedules()
    #expect(s.count == 1); #expect(s[0].scheduleKind == "interval")
    #expect(s[0].intervalHours == "8"); #expect(s[0].sortOrder == 0)
    #expect(s[0].timeOfDay == nil)
}

@Test @MainActor func rejectsEmptyNameAndBadDosage() {
    let d = validNewDraft(); d.name = ""; d.dosageAmount = "20mg"
    let errors = d.validate()
    #expect(errors.contains { $0.localizedCaseInsensitiveContains("name") })
    #expect(errors.contains { $0.localizedCaseInsensitiveContains("dosage") })
}

@Test @MainActor func rejectsTooManyRowsAndIntervalOutOfRange() {
    let d = validNewDraft()
    d.scheduleRows = (0 ... 20).map { MedicationDraft.ScheduleDraft(id: "r\($0)", kind: "interval",
                                                                    intervalHours: "8", timeOfDay: "", daysOfWeek: []) } // 21 rows
    #expect(d.validate().contains { $0.localizedCaseInsensitiveContains("schedule") })
    d.scheduleRows = [MedicationDraft.ScheduleDraft(id: "r1", kind: "interval",
                                                    intervalHours: "73", timeOfDay: "", daysOfWeek: [])] // > 72
    #expect(d.validate().contains { $0.localizedCaseInsensitiveContains("interval") })
}

@Test @MainActor func rejectsBadTimeOfDay() {
    let d = validNewDraft()
    d.scheduleRows = [MedicationDraft.ScheduleDraft(id: "r1", kind: "fixed_time",
                                                    intervalHours: "", timeOfDay: "25:99", daysOfWeek: [1, 3, 5])]
    #expect(d.validate().contains { $0.localizedCaseInsensitiveContains("time") })
}

@Test @MainActor func fixedTimeMapsDaysOfWeekSortedAndPrnClears() {
    let d = validNewDraft()
    d.scheduleRows = [
        MedicationDraft.ScheduleDraft(id: "r1", kind: "fixed_time",
                                      intervalHours: "", timeOfDay: "08:00", daysOfWeek: [5, 1, 3]),
        MedicationDraft.ScheduleDraft(id: "r2", kind: "prn",
                                      intervalHours: "6", timeOfDay: "09:00", daysOfWeek: [2]),
    ]
    #expect(d.validate().isEmpty)
    let s = d.schedules()
    #expect(s[0].timeOfDay == "08:00"); #expect(s[0].daysOfWeek == [1, 3, 5])
    #expect(s[1].scheduleKind == "prn")
    #expect(s[1].timeOfDay == nil); #expect(s[1].intervalHours == nil); #expect(s[1].daysOfWeek == nil)
}

@Test @MainActor func editModeHydratesFromRecords() {
    let d = MedicationDraft(mode: .edit(id: "m1"))
    let med = Medication(id: "m1", userId: "u", name: "Aspirin", dosageAmount: "75",
                         dosageUnit: "mg", form: "tablet", category: "otc", colour: "#ff0000",
                         inventoryCount: 30, inventoryAlertThreshold: 5, startedAt: 0, createdAt: 0, updatedAt: 0)
    let sched = MedicationSchedule(id: "s1", medicationId: "m1", userId: "u",
                                   scheduleKind: "fixed_time", timeOfDay: "08:00", daysOfWeek: [1, 2],
                                   sortOrder: 0, effectiveFrom: 0, createdAt: 0)
    d.load(from: med, schedules: [sched])
    #expect(d.name == "Aspirin"); #expect(d.trackInventory); #expect(d.inventoryCount == "30")
    #expect(d.scheduleRows.count == 1); #expect(d.scheduleRows[0].timeOfDay == "08:00")
    #expect(d.scheduleRows[0].daysOfWeek == [1, 2])
    #expect(d.validate().isEmpty)
}

// MARK: - addScheduleRow / removeScheduleRow

@Test @MainActor func addScheduleRowAppendsBlankInterval() {
    let d = validNewDraft()
    #expect(d.scheduleRows.count == 1)
    d.addScheduleRow()
    #expect(d.scheduleRows.count == 2)
    #expect(d.scheduleRows[1].kind == "interval")
    #expect(d.scheduleRows[1].intervalHours.isEmpty)
    #expect(d.scheduleRows[1].timeOfDay.isEmpty)
    #expect(d.scheduleRows[1].daysOfWeek.isEmpty)
    // Ids must be distinct so `Identifiable` list diffing behaves.
    #expect(d.scheduleRows[0].id != d.scheduleRows[1].id)
}

@Test @MainActor func removeScheduleRowRemovesAtIndex() {
    let d = validNewDraft()
    d.addScheduleRow()
    d.addScheduleRow()
    #expect(d.scheduleRows.count == 3)
    let keepFirst = d.scheduleRows[0].id
    let keepLast = d.scheduleRows[2].id
    d.removeScheduleRow(at: 1)
    #expect(d.scheduleRows.count == 2)
    #expect(d.scheduleRows[0].id == keepFirst)
    #expect(d.scheduleRows[1].id == keepLast)
}

@Test @MainActor func removeScheduleRowIgnoresOutOfBoundsIndex() {
    let d = validNewDraft()
    #expect(d.scheduleRows.count == 1)
    d.removeScheduleRow(at: 5)
    d.removeScheduleRow(at: -1)
    #expect(d.scheduleRows.count == 1)
}
