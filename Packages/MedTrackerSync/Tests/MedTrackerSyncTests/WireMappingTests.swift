import Foundation
import MedTrackerData
@testable import MedTrackerSync
import MedTrackerTestSupport
import Testing

@Test func parsesISOWithAndWithoutFractional() throws {
    #expect(try WireMapping.epoch("2026-07-26T10:00:00.000Z") == 1785060000) // pinned
    #expect(try WireMapping.epoch("2026-07-26T10:00:00Z") == 1785060000)
    #expect(throws: WireMappingError.badDate("nope")) { _ = try WireMapping.epoch("nope") }
}

@Test func mapsMedicationPreservingStrings() throws {
    let r = try JSONDecoder().decode(SyncResponse.self, from: Data(Fixtures.syncDelta.utf8))
    let m = try WireMapping.medication(r.medications[0])
    #expect(m.id == "m1")
    #expect(m.dosageAmount == "50") // stays TEXT
    #expect(m.inventoryCount == 30)
    #expect(m.updatedAt == 1785056400) // 2026-07-26T09:00:00Z, pinned
    #expect(m.archivedAt == nil)
}

@Test func mapsScheduleDaysOfWeekJSON() throws {
    let w = WireSchedule(id: "s", medicationId: "m", userId: "u", scheduleKind: "fixed_time",
                         timeOfDay: "08:00", intervalHours: nil, daysOfWeek: [1, 3, 5], sortOrder: 0,
                         effectiveFrom: "2026-07-01T00:00:00.000Z", effectiveTo: nil,
                         createdAt: "2026-07-01T00:00:00.000Z")
    let s = try WireMapping.schedule(w)
    #expect(s.daysOfWeekArray == [1, 3, 5]) // re-encoded through MedTrackerData's JSON accessor
    #expect(s.timeOfDay == "08:00")
}

@Test func mapsPreferencesCollapsingNotificationChannels() throws {
    let p = WirePreferences(userId: "u", accentColor: "#6366f1", dateFormat: "DD/MM/YYYY",
                            timeFormat: "12h", uiDensity: "comfortable", reducedMotion: false,
                            overdueEmailReminders: false, overduePushReminders: true,
                            lowInventoryEmailAlerts: false, lowInventoryPushAlerts: false,
                            doseLogPageSize: 20, heatmapPeriod: 90, exportFormat: "pdf",
                            updatedAt: "2026-07-26T10:00:00.000Z")
    let s = try WireMapping.settings(p)
    #expect(s.overdueRemindersEnabled == true) // email||push
    #expect(s.lowInventoryAlertsEnabled == false)
}
