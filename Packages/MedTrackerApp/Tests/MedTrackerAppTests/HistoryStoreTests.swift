import Foundation
import GRDB
@testable import MedTrackerApp
import MedTrackerCore
import MedTrackerData
import MedTrackerSync
import Testing

private let userId = "user_1"
private let fixedNow = Date(timeIntervalSince1970: 1_785_412_800) // 2026-07-26T12:00:00Z

private func seed(_ db: DatabaseQueue) throws {
    try db.write { d in
        try Profile(id: 1, userId: userId, email: "a@b.com", name: "A",
                    timezone: "UTC", createdAt: 0, updatedAt: 0).insert(d)
        try Medication(id: "m1", userId: userId, name: "Ibuprofen", dosageAmount: "200",
                       dosageUnit: "mg", form: "tablet", category: "otc", colour: "#3366ff",
                       startedAt: 0, createdAt: 0, updatedAt: 0).insert(d)
        try DoseLog(id: "today1", userId: userId, medicationId: "m1", quantity: 2,
                    takenAt: fixedNow.timeIntervalSince1970, loggedAt: 0, status: "taken", updatedAt: 0).insert(d)
        try DoseLog(id: "yest1", userId: userId, medicationId: "m1", quantity: 1,
                    takenAt: fixedNow.timeIntervalSince1970 - 86_400, loggedAt: 0, status: "skipped",
                    updatedAt: 0).insert(d)
    }
}

@Test func buildGroupsTodayYesterdayInProfileTZ() throws {
    let db = try MedTrackerDatabase.open(); try seed(db)
    let result = try db.read {
        try HistorySection.build($0, userId: userId, filter: HistoryFilter(), limit: 20, now: fixedNow)
    }
    #expect(result.sections.count == 2)
    #expect(result.sections[0].label == "Today")
    #expect(result.sections[0].rows[0].id == "today1")
    #expect(result.sections[0].rows[0].quantity == 2)
    #expect(result.sections[0].rows[0].status == .taken)
    #expect(result.sections[1].label == "Yesterday")
    #expect(result.sections[1].rows[0].status == .skipped)
    #expect(result.hasMore == false) // 2 rows < limit 20
}

@Test func buildReportsHasMoreAtLimit() throws {
    let db = try MedTrackerDatabase.open(); try seed(db)
    let result = try db.read {
        try HistorySection.build($0, userId: userId, filter: HistoryFilter(), limit: 1, now: fixedNow)
    }
    #expect(result.hasMore) // rows.count == limit
}

@Test @MainActor func filterChangeResetsPagingAndLoadMoreGrows() throws {
    let db = try MedTrackerDatabase.open()
    let store = HistoryStore(dbWriter: db, userId: userId,
                             writeCoordinator: WriteCoordinator(dbWriter: db, outbox: OutboxStore(dbWriter: db), userId: userId))
    store.loadMore(); store.loadMore()
    #expect(store.loadedPages == 3)
    #expect(store.observationKey.limit == 60) // 3 × pageSize 20
    store.filter.status = "taken"
    #expect(store.loadedPages == 1) // filter change resets
    #expect(store.observationKey.limit == 20)
}

@Test @MainActor func deleteDoseRemovesRowAndEnqueuesCommand() async throws {
    let db = try MedTrackerDatabase.open(); try seed(db)
    let outbox = OutboxStore(dbWriter: db)
    let store = HistoryStore(dbWriter: db, userId: userId,
                             writeCoordinator: WriteCoordinator(dbWriter: db, outbox: outbox, userId: userId))
    try await store.deleteDose(doseId: "today1")
    try await db.read { d in
        try #expect(DoseLog.fetchOne(d, key: "today1") == nil)
        try #expect(OutboxEntry.filter(Column("command_type") == "delete_dose").fetchCount(d) == 1)
    }
}

@Test @MainActor func editDoseRoutesThroughCoordinator() async throws {
    let db = try MedTrackerDatabase.open(); try seed(db)
    let outbox = OutboxStore(dbWriter: db)
    let store = HistoryStore(dbWriter: db, userId: userId,
                             writeCoordinator: WriteCoordinator(dbWriter: db, outbox: outbox, userId: userId))
    try await store.editDose(doseId: "today1", takenAt: nil, quantity: 5, notes: nil, sideEffects: nil)
    try await db.read { d in
        let fetched = try DoseLog.fetchOne(d, key: "today1")
        let dose = try #require(fetched)
        #expect(dose.quantity == 5)
        try #expect(OutboxEntry.filter(Column("command_type") == "edit_dose").fetchCount(d) == 1)
    }
}

// MARK: - Reconciliation: Settings.dateFormat honored (NOT hardcoded `.medium`)

@Test func absoluteDateLabelHonorsSettingsDateFormatMMDDYYYY() throws {
    let db = try MedTrackerDatabase.open()
    try db.write { d in
        try Profile(id: 1, userId: userId, email: "a@b.com", name: "A",
                    timezone: "UTC", createdAt: 0, updatedAt: 0).insert(d)
        try Settings(dateFormat: "MM/DD/YYYY", updatedAt: 0).insert(d)
        try Medication(id: "m1", userId: userId, name: "Ibuprofen", dosageAmount: "200",
                       dosageUnit: "mg", form: "tablet", category: "otc", colour: "#3366ff",
                       startedAt: 0, createdAt: 0, updatedAt: 0).insert(d)
        // 3 days before fixedNow → neither Today nor Yesterday.
        try DoseLog(id: "old1", userId: userId, medicationId: "m1", quantity: 1,
                    takenAt: fixedNow.timeIntervalSince1970 - 3 * 86_400, loggedAt: 0, status: "taken",
                    updatedAt: 0).insert(d)
    }
    let result = try db.read {
        try HistorySection.build($0, userId: userId, filter: HistoryFilter(), limit: 20, now: fixedNow)
    }
    #expect(result.sections.count == 1)
    #expect(result.sections[0].label == "07/27/2026") // MM/DD/YYYY, not a `.medium` "Jul 27, 2026"
}

@Test func absoluteDateLabelDefaultsToDDMMYYYYWhenSettingsAbsent() throws {
    let db = try MedTrackerDatabase.open()
    try db.write { d in
        try Profile(id: 1, userId: userId, email: "a@b.com", name: "A",
                    timezone: "UTC", createdAt: 0, updatedAt: 0).insert(d)
        try Medication(id: "m1", userId: userId, name: "Ibuprofen", dosageAmount: "200",
                       dosageUnit: "mg", form: "tablet", category: "otc", colour: "#3366ff",
                       startedAt: 0, createdAt: 0, updatedAt: 0).insert(d)
        try DoseLog(id: "old1", userId: userId, medicationId: "m1", quantity: 1,
                    takenAt: fixedNow.timeIntervalSince1970 - 3 * 86_400, loggedAt: 0, status: "taken",
                    updatedAt: 0).insert(d)
    }
    let result = try db.read {
        try HistorySection.build($0, userId: userId, filter: HistoryFilter(), limit: 20, now: fixedNow)
    }
    #expect(result.sections[0].label == "27/07/2026") // Settings' own default: DD/MM/YYYY
}

// MARK: - Reconciliation: Settings.doseLogPageSize honored (NOT hardcoded `20`)

@Test @MainActor func observeUsesSettingsDoseLogPageSizeOverConstructorDefault() async throws {
    let db = try MedTrackerDatabase.open()
    try await db.write { d in
        try Profile(id: 1, userId: userId, email: "a@b.com", name: "A",
                    timezone: "UTC", createdAt: 0, updatedAt: 0).insert(d)
        try Settings(doseLogPageSize: 2, updatedAt: 0).insert(d)
        try Medication(id: "m1", userId: userId, name: "Ibuprofen", dosageAmount: "200",
                       dosageUnit: "mg", form: "tablet", category: "otc", colour: "#3366ff",
                       startedAt: 0, createdAt: 0, updatedAt: 0).insert(d)
        for i in 0 ..< 3 {
            try DoseLog(id: "d\(i)", userId: userId, medicationId: "m1", quantity: 1,
                        takenAt: fixedNow.timeIntervalSince1970 - Double(i) * 3600, loggedAt: 0,
                        status: "taken", updatedAt: 0).insert(d)
        }
    }
    // Constructor default pageSize is 20; the store should honor Settings' 2 instead.
    let store = HistoryStore(dbWriter: db, userId: userId,
                             writeCoordinator: WriteCoordinator(dbWriter: db, outbox: OutboxStore(dbWriter: db), userId: userId))
    let task = Task { await store.observe() }
    var tries = 0
    while store.sections.isEmpty, tries < 100 {
        try await Task.sleep(nanoseconds: 10_000_000); tries += 1
    }
    task.cancel()
    let totalRows = store.sections.reduce(0) { $0 + $1.rows.count }
    #expect(totalRows == 2) // limit 2 (Settings doseLogPageSize), not 20
    #expect(store.hasMore) // rows.count == limit
}
