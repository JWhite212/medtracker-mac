import Foundation

/// Debounced trigger for post-write / foreground / manual re-syncs (§3.4, §4.4).
/// Coalesces bursts within `debounce` and DROPS a request if a sync is already
/// running — `SyncEngine` is reentrant and idempotent, so coalescing is an
/// efficiency, not a correctness, concern.
@MainActor public final class SyncScheduler {
    private let debounce: Duration
    private let runSync: @Sendable () async -> Void
    private var debounceTask: Task<Void, Never>?
    private var isRunning = false

    public init(debounce: Duration = .milliseconds(500),
                runSync: @escaping @Sendable () async -> Void)
    {
        self.debounce = debounce
        self.runSync = runSync
    }

    /// Schedules a sync after the debounce window, cancelling any pending one.
    /// When the window elapses, fires only if no sync is currently in flight.
    public func requestSync() {
        if !isRunning {
            debounceTask?.cancel()
            debounceTask = Task { [weak self, debounce] in
                try? await Task.sleep(for: debounce)
                guard !Task.isCancelled else { return }
                await self?.fire()
            }
        }
    }

    private func fire() async {
        guard !isRunning else { return } // drop-if-in-flight
        isRunning = true
        defer { isRunning = false }
        await runSync()
    }
}
