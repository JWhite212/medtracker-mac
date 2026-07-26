import Foundation
import GRDB
@testable import MedTrackerApp
import MedTrackerCore
import MedTrackerData
import Testing

private let userId = "user_1"
// A fixed instant so slot/day math is deterministic (2026-07-26T12:00:00Z).
private let fixedNow = Date(timeIntervalSince1970: 1_785_412_800)

private func seededDB(archivedOnly: Bool = false, empty: Bool = false) throws -> DatabaseQueue {
    let db = try MedTrackerDatabase.open()
    try db.write { d in
        try Profile(id: 1, userId: userId, email: "a@b.com", name: "A",
                    timezone: "UTC", createdAt: 0, updatedAt: 0).insert(d)
        if empty { return }
        var med = Medication(id: "m1", userId: userId, name: "Ibuprofen",
                             dosageAmount: "200", dosageUnit: "mg", form: "tablet", category: "otc",
                             colour: "#ff0000", inventoryCount: 2, inventoryAlertThreshold: 5,
                             sortOrder: 0, startedAt: 0, createdAt: 0, updatedAt: 0)
        med.isArchived = archivedOnly
        try med.insert(d)
        // A fixed-time slot at local midnight — always <= fixedNow, so overdue & untaken.
        try MedicationSchedule(id: "s1", medicationId: "m1", userId: userId,
                               scheduleKind: "fixed_time", timeOfDay: "00:00", daysOfWeek: nil,
                               sortOrder: 0, effectiveFrom: 0, createdAt: 0).insert(d)
    }
    return db
}

@Test func buildIsEmptyWithNoActiveMeds() throws {
    let db = try seededDB(archivedOnly: true)
    let snap = try db.read { try DashboardSnapshot.build($0, userId: userId, now: fixedNow) }
    #expect(snap.isEmpty)
    #expect(snap.timeZoneID == "UTC")
    #expect(snap.quickLog.isEmpty)
}

@Test func buildComputesSlotsSummaryRefillsQuickLog() throws {
    let db = try seededDB()
    let snap = try db.read { try DashboardSnapshot.build($0, userId: userId, now: fixedNow) }
    #expect(!snap.isEmpty)
    #expect(snap.quickLog.count == 1)
    #expect(snap.summary.scheduledCount == 1)
    #expect(snap.summary.takenCount == 0)
    #expect(snap.summary.adherencePercent == 0) // due-so-far denominator = 1, taken = 0
    #expect(snap.todayFeed.count == 1) // the overdue slot
    #expect(snap.todayFeed[0].medicationId == "m1")
    #expect(snap.myDay.contains { $0.bucket == .night }) // 00:00 → night bucket
    let refill = try #require(snap.refills.first)
    #expect(refill.isLowInventory) // inv 2 <= threshold 5
}

@Test @MainActor func observeEmitsInitialSnapshot() async throws {
    let db = try seededDB()
    let store = DashboardStore(dbWriter: db, userId: userId)
    let task = Task { await store.observe() }
    var tries = 0
    while store.snapshot.isEmpty, tries < 100 {
        try await Task.sleep(nanoseconds: 10_000_000); tries += 1
    }
    task.cancel()
    #expect(store.snapshot.quickLog.count == 1)
    #expect(store.loadError == nil)
}
