import Foundation
import GRDB
@testable import MedTrackerApp
import MedTrackerCore
import MedTrackerData
import Testing

private let userId = "user_1"
private let fixedNow = Date(timeIntervalSince1970: 1_785_412_800) // 2026-07-26T12:00:00Z

private func seed(_ db: DatabaseQueue, intervalHours: String? = "8",
                  lastTakenOffset: TimeInterval? = -3600, archived: Bool = false) throws
{
    try db.write { d in
        try Profile(id: 1, userId: userId, email: "a@b.com", name: "A",
                    timezone: "UTC", createdAt: 0, updatedAt: 0).insert(d)
        var med = Medication(id: "m1", userId: userId, name: "Ibuprofen", dosageAmount: "200",
                             dosageUnit: "mg", form: "tablet", category: "otc", colour: "#3366ff",
                             inventoryCount: 40, inventoryAlertThreshold: 5, sortOrder: 0,
                             startedAt: 0, createdAt: 0, updatedAt: 0)
        med.isArchived = archived
        try med.insert(d)
        try MedicationSchedule(id: "s1", medicationId: "m1", userId: userId,
                               scheduleKind: "interval", intervalHours: intervalHours, sortOrder: 0,
                               effectiveFrom: 0, createdAt: 0).insert(d)
        // Two taken doses on two distinct recent days → sparkline draws a line.
        for (i, offset) in [86_400.0 * 2, 86_400.0].enumerated() {
            try DoseLog(id: "d\(i)", userId: userId, medicationId: "m1", quantity: 1,
                        takenAt: fixedNow.timeIntervalSince1970 - offset,
                        loggedAt: fixedNow.timeIntervalSince1970 - offset, status: "taken",
                        updatedAt: 0).insert(d)
        }
        if let lastTakenOffset {
            try DoseLog(id: "dl", userId: userId, medicationId: "m1", quantity: 1,
                        takenAt: fixedNow.timeIntervalSince1970 + lastTakenOffset,
                        loggedAt: 0, status: "taken", updatedAt: 0).insert(d)
        }
    }
}

@Test func buildCardComputesRefillAdherenceSparklineBadge() throws {
    let db = try MedTrackerDatabase.open(); try seed(db)
    let snap = try db.read { try MedicationsSnapshot.build($0, userId: userId, now: fixedNow) }
    #expect(snap.active.count == 1); #expect(snap.archived.isEmpty)
    let card = snap.active[0]
    #expect(card.refillSeverity != .ok) // 40 units / 3 per day → ~13d → .watch
    #expect(!card.isLowInventory) // 40 > threshold 5
    #expect(card.adherencePercent > 0)
    #expect(!card.sparkline.line.isEmpty) // ≥2 non-empty days
    let badge = try #require(card.timingBadge) // interval + last-taken → non-nil
    let plausibleStatuses: [TimingStatus] = [.ok, .dueSoon, .dueNow, .overdue]
    #expect(plausibleStatuses.contains(badge.status))
}

@Test func intervalNeverTakenHasNoBadge() throws {
    let db = try MedTrackerDatabase.open(); try seed(db, lastTakenOffset: nil)
    // remove the two seeded taken doses so there is no last-taken anchor at all
    try db.write { _ = try DoseLog.deleteAll($0) }
    let snap = try db.read { try MedicationsSnapshot.build($0, userId: userId, now: fixedNow) }
    #expect(snap.active[0].timingBadge == nil) // kept quirk §5.2.5 / §15
}

@Test func archivedMedsPartitioned() throws {
    let db = try MedTrackerDatabase.open(); try seed(db, archived: true)
    let snap = try db.read { try MedicationsSnapshot.build($0, userId: userId, now: fixedNow) }
    #expect(snap.active.isEmpty); #expect(snap.archived.count == 1)
    #expect(snap.archived[0].isArchived)
}

@Test func detailReadsInventoryEventHistoryNewestFirst() throws {
    let db = try MedTrackerDatabase.open(); try seed(db)
    try db.write { d in
        try InventoryEvent(id: "e1", userId: userId, medicationId: "m1", eventType: "refill",
                           quantityChange: 30, previousCount: 10, newCount: 40, createdAt: 100).insert(d)
        try InventoryEvent(id: "e2", userId: userId, medicationId: "m1", eventType: "manual_adjustment",
                           quantityChange: -5, previousCount: 45, newCount: 40, createdAt: 200).insert(d)
    }
    let detail = try db.read { try MedicationDetailVM.build($0, userId: userId, medicationId: "m1", now: fixedNow) }
    let d = try #require(detail)
    #expect(d.card.id == "m1")
    #expect(d.schedules.count == 1)
    #expect(d.inventoryEvents.map(\.id) == ["e2", "e1"]) // created_at DESC
}
