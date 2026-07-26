import Foundation
import Testing
@testable import MedTrackerApp

private actor Counter {
    private(set) var count = 0
    func inc() { count += 1 }
}

@MainActor @Test func coalescesRapidRequestsIntoOneRun() async throws {
    let counter = Counter()
    let scheduler = SyncScheduler(debounce: .milliseconds(50)) { await counter.inc() }
    scheduler.requestSync()
    scheduler.requestSync()
    scheduler.requestSync()                    // three bursts inside one debounce window
    try await Task.sleep(for: .milliseconds(200))
    #expect(await counter.count == 1)          // only the trailing edge fires
}

@MainActor @Test func dropsRequestWhileASyncIsInFlight() async throws {
    let counter = Counter()
    let scheduler = SyncScheduler(debounce: .milliseconds(20)) {
        await counter.inc()
        try? await Task.sleep(for: .milliseconds(150))   // long-running sync
    }
    scheduler.requestSync()
    try await Task.sleep(for: .milliseconds(60))          // first run has started, still in flight
    scheduler.requestSync()                               // its debounce elapses mid-flight → dropped
    try await Task.sleep(for: .milliseconds(120))
    #expect(await counter.count == 1)
    try await Task.sleep(for: .milliseconds(200))         // let the first run settle out
}

@MainActor @Test func runsAgainAfterPreviousRunCompletes() async throws {
    let counter = Counter()
    let scheduler = SyncScheduler(debounce: .milliseconds(20)) { await counter.inc() }
    scheduler.requestSync()
    try await Task.sleep(for: .milliseconds(80))
    scheduler.requestSync()                               // fresh request after the first finished
    try await Task.sleep(for: .milliseconds(80))
    #expect(await counter.count == 2)
}
