import Foundation
import GRDB
@testable import MedTrackerApp
import MedTrackerData
import MedTrackerSync
import Testing

@MainActor
private func makeModel() throws -> (DatabaseQueue, AppModel) {
    let db = try MedTrackerDatabase.open()
    let coord = WriteCoordinator(dbWriter: db, outbox: OutboxStore(dbWriter: db), userId: "u1")
    let scheduler = SyncScheduler(debounce: .milliseconds(50)) {}
    let model = AppModel(dbWriter: db, userId: "u1", writeCoordinator: coord, syncScheduler: scheduler)
    return (db, model)
}

@Test func sidebarHasExactlyThreeDestinations() {
    #expect(SidebarItem.allCases == [.dashboard, .medications, .history])
}

@MainActor @Test func timeZoneFallsBackToUTCWithoutProfile() throws {
    let (_, model) = try makeModel()
    #expect(model.profile == nil)
    // Compared against a fresh `TimeZone(identifier: "UTC")!` rather than the literal "UTC" —
    // this Foundation canonicalizes that identifier to "GMT", but the offset is still zero;
    // what matters is the fallback matches a plain UTC construction exactly.
    #expect(model.timeZone.identifier == TimeZone(identifier: "UTC")!.identifier)
    #expect(model.timeZone.secondsFromGMT() == 0)
}

@MainActor @Test func observeProfileReflectsSyncedTimezone() async throws {
    let (db, model) = try makeModel()
    try await db.write { d in
        try Profile(id: 1, userId: "u1", email: "a@b.com", name: "A",
                    timezone: "Europe/London", createdAt: 0, updatedAt: 0).insert(d)
    }
    let task = Task { await model.observeProfile() }
    // await the first observation emission (view-driven task, §2.6)
    var waited = 0
    while model.profile == nil, waited < 200 {
        try await Task.sleep(for: .milliseconds(10)); waited += 1
    }
    #expect(model.profile?.timezone == "Europe/London")
    #expect(model.timeZone.identifier == "Europe/London")
    task.cancel()
}

@MainActor @Test func observeProfilePicksUpAProfileUpdate() async throws {
    let (db, model) = try makeModel()
    let task = Task { await model.observeProfile() }
    try await db.write { d in
        try Profile(id: 1, userId: "u1", email: "a@b.com", name: "A",
                    timezone: "America/New_York", createdAt: 0, updatedAt: 0).insert(d)
    }
    var waited = 0
    while model.timeZone.identifier != "America/New_York", waited < 200 {
        try await Task.sleep(for: .milliseconds(10)); waited += 1
    }
    #expect(model.timeZone.identifier == "America/New_York")
    task.cancel()
}

@MainActor @Test func settingsStartsNilBeforeObservation() throws {
    let (_, model) = try makeModel()
    #expect(model.settings == nil)
}

@MainActor @Test func observeSettingsReflectsSyncedSettings() async throws {
    let (db, model) = try makeModel()
    try await db.write { d in
        try Settings(id: 1, dateFormat: "MM/DD/YYYY", timeFormat: "24h",
                     doseLogPageSize: 50, updatedAt: 0).insert(d)
    }
    let task = Task { await model.observeSettings() }
    var waited = 0
    while model.settings == nil, waited < 200 {
        try await Task.sleep(for: .milliseconds(10)); waited += 1
    }
    #expect(model.settings?.dateFormat == "MM/DD/YYYY")
    #expect(model.settings?.timeFormat == "24h")
    #expect(model.settings?.doseLogPageSize == 50)
    task.cancel()
}

@MainActor @Test func observeSettingsPicksUpASettingsUpdate() async throws {
    let (db, model) = try makeModel()
    let task = Task { await model.observeSettings() }
    try await db.write { d in
        try Settings(id: 1, reducedMotion: true, updatedAt: 0).insert(d)
    }
    var waited = 0
    while model.settings == nil, waited < 200 {
        try await Task.sleep(for: .milliseconds(10)); waited += 1
    }
    #expect(model.settings?.reducedMotion == true)

    try await db.write { d in
        var s = try Settings.fetchOne(d, key: 1)!
        s.reducedMotion = false
        s.updatedAt = 1
        try s.update(d)
    }
    waited = 0
    while model.settings?.reducedMotion != false, waited < 200 {
        try await Task.sleep(for: .milliseconds(10)); waited += 1
    }
    #expect(model.settings?.reducedMotion == false)
    task.cancel()
}
