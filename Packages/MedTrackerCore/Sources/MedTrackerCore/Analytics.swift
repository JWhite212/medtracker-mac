import Foundation

// Ports the pure math from `src/lib/server/analytics.ts` (`calculateAdherence`
// → `adherencePercent`, `calculateOveruse` → `overusePercent`, `:98-108`;
// `calculateTrend`, `:66-76`; `calculateStreak`, `:78-94`) and the whole of
// `src/lib/server/analytics/lifecycle.ts` (`clampEffectiveDays`, `isActiveOn`).
//
// Deliberately NOT ported here (belong to later phases / other tasks):
//   - `getPerMedicationStats`, `getDailyDoseCounts`, `getDailyAdherenceSeries`,
//     `getDoseStatusBreakdown`, `getHourlyDistribution`,
//     `getDayOfWeekDistribution`, `getScheduleVariance`, `getSideEffectStats`
//     — all run SQL against `db` and need the persistence layer.
//   - `buildInsights` — deterministic insights engine, Task 7 (Insights.swift).
//   - `expectedPerDayForSchedules` — already implemented in Inventory.swift as
//     `expectedPerDay(forSchedules:)` (Task 5); reused here, not reimplemented.
//
// `calculateStreak` takes `today` as an explicit parameter rather than
// resolving "today" internally via `Intl.DateTimeFormat` (as the TS does) —
// callers resolve the caller's local "today" string themselves (e.g. via
// `localDateString`) and pass it in, keeping this function pure and
// testable without a wall-clock or timezone dependency.

private let utcTimeZone = TimeZone(identifier: "UTC")!
private let secondsPerDay: TimeInterval = 86_400

// MARK: - Adherence / overuse

/// Visual adherence: capped at 100% so a bar never overshoots. Ports
/// `calculateAdherence` (`analytics.ts:98-102`). `0` when `expected == 0`;
/// otherwise `min(100, jsRound(taken/expected*1000)/10)` — a 1-decimal
/// percentage, matching the TS `Math.round(x*1000)/10` shape exactly.
public func adherencePercent(taken: Int, expected: Int) -> Double {
    guard expected != 0 else { return 0 }
    let raw = Double(jsRound(Double(taken) / Double(expected) * 1000)) / 10
    return min(100, raw)
}

/// The over-100% overflow `adherencePercent` caps away. Ports
/// `calculateOveruse` (`analytics.ts:104-108`). `0` when `expected == 0` or
/// `taken <= expected`; otherwise `jsRound((taken-expected)/expected*1000)/10`.
public func overusePercent(taken: Int, expected: Int) -> Double {
    guard expected != 0 else { return 0 }
    guard taken > expected else { return 0 }
    return Double(jsRound(Double(taken - expected) / Double(expected) * 1000)) / 10
}

// MARK: - Trend

/// Mirrors the TS `calculateTrend` return union's `direction` field
/// (`"up" | "down" | "flat"`, `analytics.ts:66-76`).
public enum TrendDirection: Equatable, Hashable {
    case up
    case down
    case flat
}

/// Ports `calculateTrend` (`analytics.ts:66-76`). `(0,0)` → `(.flat, 0)`;
/// `previous == 0` (and current non-zero) → `(.up, 100)`; otherwise the
/// percent change is `jsRound(abs((current-previous)/previous*100))` — `0`
/// rounds to `.flat`, else direction follows the sign of `current-previous`.
public func calculateTrend(current: Double, previous: Double) -> (direction: TrendDirection, percent: Int) {
    if previous == 0, current == 0 { return (.flat, 0) }
    if previous == 0 { return (.up, 100) }

    let change = (current - previous) / previous * 100
    let rounded = jsRound(abs(change))
    if rounded == 0 { return (.flat, 0) }
    return (change > 0 ? .up : .down, rounded)
}

// MARK: - Streak

/// Parses a `yyyy-MM-dd` string as UTC midnight, mirroring JS `new
/// Date("yyyy-MM-dd")` (an ISO date-only string is always interpreted as UTC
/// midnight per the ECMAScript spec). Reuses the Task 3 `wallClockToUTC`
/// primitive rather than reimplementing date parsing. `nil` on malformed input.
private func parseDateStringAsUTCMidnight(_ s: String) -> Date? {
    let parts = s.split(separator: "-")
    guard parts.count == 3,
          let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
    else { return nil }
    return wallClockToUTC(year: year, month: month, day: day, hour: 0, minute: 0, timeZone: utcTimeZone)
}

/// Ports `calculateStreak` (`analytics.ts:78-94`). `dateStringsNewestFirst`
/// are `yyyy-MM-dd` calendar dates with logged activity, newest first. `0`
/// unless the first date equals `today`; otherwise counts consecutive
/// entries while the gap to the previous entry rounds to exactly 1 day
/// (`jsRound((prev-curr)/86_400_000) == 1`), stopping at the first larger
/// gap (or unparseable entry).
public func calculateStreak(dateStringsNewestFirst dates: [String], today: String) -> Int {
    guard !dates.isEmpty else { return 0 }
    guard dates[0] == today else { return 0 }

    var streak = 1
    for i in 1 ..< dates.count {
        guard
            let prev = parseDateStringAsUTCMidnight(dates[i - 1]),
            let curr = parseDateStringAsUTCMidnight(dates[i])
        else { break }

        let diffDays = prev.timeIntervalSince(curr) / secondsPerDay
        if jsRound(diffDays) == 1 {
            streak += 1
        } else {
            break
        }
    }
    return streak
}

// MARK: - Lifecycle clamping

/// Number of days in the intersection of `[rangeFrom, rangeTo]` and
/// `[startedAt, endedAt ?? +∞]`. Ports `clampEffectiveDays`
/// (`lifecycle.ts:18-34`). `0` when the lifecycle window doesn't overlap the
/// range at all (e.g. a med added today being asked about last week's
/// adherence) — including when the overlap is under 12 hours, which rounds
/// down to `0`.
public func clampEffectiveDays(rangeFrom: Date, rangeTo: Date, startedAt: Date, endedAt: Date?) -> Int {
    let effFrom = max(rangeFrom, startedAt)
    let effTo = endedAt.map { min(rangeTo, $0) } ?? rangeTo

    if effTo <= effFrom { return 0 }
    return max(0, jsRound(effTo.timeIntervalSince(effFrom) / secondsPerDay))
}

/// Is `date` inside `[startedAt, endedAt]`? Ports `isActiveOn`
/// (`lifecycle.ts:41-46`). `endedAt == nil` means open on the right (med
/// still active); both boundary instants are inclusive.
public func isActiveOn(_ date: Date, startedAt: Date, endedAt: Date?) -> Bool {
    if date < startedAt { return false }
    if let endedAt, date > endedAt { return false }
    return true
}
