import Foundation
@testable import MedTrackerApp
import Testing

private actor Counter {
    private(set) var count = 0
    func inc() {
        count += 1
    }
}

/// Polls until `condition` holds, or gives up at `timeout`.
///
/// These tests previously slept for a fixed duration and then asserted. That
/// races the scheduler's real async work whenever the suite runs in parallel
/// under load — `runsAgainAfterPreviousRunCompletes` failed intermittently in
/// exactly that way. Waiting for the observable outcome keeps the tests fast in
/// the common case and removes the dependency on wall-clock luck.
private func waitUntil(
    timeout: Duration = .seconds(5),
    _ condition: @Sendable () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

/// Lets any already-scheduled work reach the counter before a "did NOT happen"
/// assertion. Only used for negative expectations, which cannot be polled for.
private func settle() async {
    try? await Task.sleep(for: .milliseconds(250))
}

@MainActor @Test func coalescesRapidRequestsIntoOneRun() async {
    let counter = Counter()
    let scheduler = SyncScheduler(debounce: .milliseconds(50)) { await counter.inc() }
    scheduler.requestSync()
    scheduler.requestSync()
    scheduler.requestSync() // three bursts inside one debounce window

    #expect(await waitUntil { await counter.count >= 1 }, "the trailing edge never fired")
    await settle()
    #expect(await counter.count == 1) // ...and only the trailing edge fired
}

@MainActor @Test func dropsRequestWhileASyncIsInFlight() async {
    let counter = Counter()
    let started = Counter()
    let scheduler = SyncScheduler(debounce: .milliseconds(20)) {
        await started.inc()
        await counter.inc()
        try? await Task.sleep(for: .milliseconds(150)) // long-running sync
    }
    scheduler.requestSync()

    // Wait for the first run to actually be in flight rather than assuming it is.
    #expect(await waitUntil { await started.count == 1 }, "first run never started")
    scheduler.requestSync() // its debounce elapses mid-flight → dropped

    await settle()
    #expect(await counter.count == 1)
}

@MainActor @Test func runsAgainAfterPreviousRunCompletes() async {
    let counter = Counter()
    let scheduler = SyncScheduler(debounce: .milliseconds(20)) { await counter.inc() }

    scheduler.requestSync()
    #expect(await waitUntil { await counter.count == 1 }, "first run never completed")

    scheduler.requestSync() // fresh request after the first finished
    #expect(await waitUntil { await counter.count == 2 }, "second run never fired")
}
