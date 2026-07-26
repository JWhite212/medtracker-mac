import Foundation

// MARK: - Calendar helper

/// A proleptic-Gregorian calendar pinned to `timeZone`. All of the date math
/// in this file goes through this so that DST gaps and ambiguous hours are
/// resolved by Foundation's native, DST-correct primitives
/// (`Calendar.startOfDay(for:)`, `Calendar.date(from:)`, component extraction)
/// rather than by the `Intl`-offset-subtraction arithmetic the TS port uses.
private func gregorianCalendar(_ timeZone: TimeZone) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    return calendar
}

// MARK: - Relative time formatting

/// Human-readable "time since" string. Ports `formatTimeSince` from
/// `src/lib/utils/time.ts`. Unlike the TS version (which reads `Date.now()`
/// internally) `now` is passed explicitly for testability.
///
/// - `< 60s`  → `"just now"`
/// - `< 60m`  → `"{m}m ago"`
/// - `< 24h`  → `"{h}h {m}m ago"`  (minutes are the remainder, `mins % 60`)
/// - else     → `"{d}d ago"`
///
/// Every component floors, matching the TS `Math.floor` chain.
public func formatTimeSince(_ from: Date, now: Date) -> String {
    let diffSecs = Int(floor(now.timeIntervalSince(from)))
    let diffMins = Int(floor(Double(diffSecs) / 60))
    let diffHours = Int(floor(Double(diffMins) / 60))
    let diffDays = Int(floor(Double(diffHours) / 24))

    if diffSecs < 60 { return "just now" }
    if diffMins < 60 { return "\(diffMins)m ago" }
    if diffHours < 24 { return "\(diffHours)h \(diffMins % 60)m ago" }
    return "\(diffDays)d ago"
}

/// Human-readable "due in" string. Ports `formatDueIn` from
/// `src/lib/utils/time.ts`. Positive ms = time until due; negative = overdue.
///
/// - `|ms| < 60000` (i.e. `< 1` whole minute) → `"Due now"`
/// - otherwise `"Due in {h}h {m}m"` / `"Overdue {h}h {m}m"`, dropping a
///   zero hours **or** zero minutes component.
public func formatDueIn(msUntilDue ms: Double) -> String {
    let absMins = Int(floor(abs(ms) / 60_000))
    if absMins < 1 { return "Due now" }

    let hours = absMins / 60
    let mins = absMins % 60

    let label: String
    if hours > 0 && mins > 0 {
        label = "\(hours)h \(mins)m"
    } else if hours > 0 {
        label = "\(hours)h"
    } else {
        label = "\(mins)m"
    }

    return ms > 0 ? "Due in \(label)" : "Overdue \(label)"
}

// MARK: - Local date primitives

/// The UTC instant of local midnight (00:00) for `date`'s calendar day in
/// `timeZone`. Ports `startOfDay` from `src/lib/utils/time.ts`, but uses
/// Foundation's `Calendar.startOfDay(for:)` instead of the TS offset math.
public func startOfDay(_ date: Date, timeZone: TimeZone) -> Date {
    gregorianCalendar(timeZone).startOfDay(for: date)
}

/// The local calendar date of `date` in `timeZone`, formatted `yyyy-MM-dd`
/// (the `en-CA` shape the TS uses). Built from calendar components so the
/// output is locale- and digit-shape-independent.
public func localDateString(_ date: Date, timeZone: TimeZone) -> String {
    let components = gregorianCalendar(timeZone).dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", components.year!, components.month!, components.day!)
}

/// The local day of week of `date` in `timeZone`, `0 = Sunday … 6 = Saturday`
/// (matching the JS `Date.getDay()` / Postgres `dow` convention). Foundation's
/// `Calendar.component(.weekday)` returns `1 = Sunday … 7 = Saturday`, so we
/// subtract 1.
public func localDayOfWeek(_ date: Date, timeZone: TimeZone) -> Int {
    gregorianCalendar(timeZone).component(.weekday, from: date) - 1
}

/// Resolve a wall-clock time (`year-month-day hour:minute`, seconds = 0) in
/// `timeZone` to the corresponding UTC instant, DST-aware.
///
/// This is the DST-critical primitive. It delegates to Foundation's
/// `Calendar.date(from:)`, which resolves the two hard cases natively:
/// - **Spring-forward gap** (a wall-clock time that never occurs): Foundation
///   resolves it forward.
/// - **Fall-back ambiguous hour** (a wall-clock time that occurs twice):
///   Foundation picks the first (earlier) occurrence.
///
/// The exact instants for both cases are pinned by the DST parity tests in
/// `TimeTests.swift`, cross-checked against the TS `localTimeOnDateToUtc`
/// offset-subtraction result (`schedule.ts:74-101`).
public func wallClockToUTC(
    year: Int,
    month: Int,
    day: Int,
    hour: Int,
    minute: Int,
    timeZone: TimeZone
) -> Date {
    var components = DateComponents()
    components.year = year
    components.month = month
    components.day = day
    components.hour = hour
    components.minute = minute
    components.second = 0
    return gregorianCalendar(timeZone).date(from: components)!
}
