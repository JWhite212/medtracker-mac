import Foundation

/// Deterministic clock for tests: a fixed instant injected wherever production code
/// would read `Date()`. Snapshot and date-bucketing tests pass `FixedClock.reference`
/// (or a custom instant) so output never depends on wall-clock time.
public struct FixedClock: Sendable {
    public let now: Date

    public init(now: Date) {
        self.now = now
    }

    public init(epoch: Double) {
        now = Date(timeIntervalSince1970: epoch)
    }

    public var epoch: Double {
        now.timeIntervalSince1970
    }

    /// 2026-07-26T10:00:00Z — matches `Fixtures.syncDelta` `serverTime`/`cursor`.
    public static let reference = FixedClock(epoch: 1_785_060_000)
}
