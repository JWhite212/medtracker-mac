import Foundation
@testable import MedTrackerCore
import Testing

// Ports the in-scope cases of `tests/unit/time.test.ts`.
//
// time.test.ts exercises six functions. Three belong to *this* task (Task 3):
//   • formatTimeSince   → transcribed below (5 cases)
//   • formatDueIn       → transcribed below (4 cases)
//   • startOfDay        → transcribed below (1 case)
// The remaining three are owned by later tasks per the Phase 1a plan and are
// transcribed there, not here (transcribing them now would not compile and
// would pre-empt those tasks):
//   • computeTimingStatus     → Task 4 (Schedule.swift)
//   • calculateDaysUntilRefill → Task 5 (Inventory.swift)
//   • formatTime / formatUserTime (Intl locale display formatter) → not part
//     of the domain-core interface list.
//
// Task 3 additionally ADDS the DST parity tests (bottom of file) — the new
// safety net that does not exist in the TS suite.

private func d(_ s: String) -> Date {
    ISO8601DateFormatter().date(from: s)!
}

private let utc = TimeZone(identifier: "UTC")!
private let nyc = TimeZone(identifier: "America/New_York")!

// MARK: - formatTimeSince (verbatim from time.test.ts)
// TS mocked `Date.now()` to 2026-04-15T14:30:00Z; here `now` is passed explicitly.

private let now = d("2026-04-15T14:30:00Z")

@Test func formatsSecondsAgo() {
    let thirtySecsAgo = d("2026-04-15T14:29:30Z")
    #expect(formatTimeSince(thirtySecsAgo, now: now) == "just now")
}

@Test func formatsMinutesAgo() {
    let fiveMinsAgo = d("2026-04-15T14:25:00Z")
    #expect(formatTimeSince(fiveMinsAgo, now: now) == "5m ago")
}

@Test func formatsHoursAndMinutesAgo() {
    let twoHoursAgo = d("2026-04-15T12:00:00Z")
    #expect(formatTimeSince(twoHoursAgo, now: now) == "2h 30m ago")
}

@Test func formatsDaysAgo() {
    let twoDaysAgo = d("2026-04-13T14:30:00Z")
    #expect(formatTimeSince(twoDaysAgo, now: now) == "2d ago")
}

@Test func formatsExactHours() {
    let oneHourAgo = d("2026-04-15T13:30:00Z")
    #expect(formatTimeSince(oneHourAgo, now: now) == "1h 0m ago")
}

// MARK: - formatDueIn (verbatim from time.test.ts)

@Test func formatDueIn_dueNowForNearZero() {
    #expect(formatDueIn(msUntilDue: 0) == "Due now")
    #expect(formatDueIn(msUntilDue: 30_000) == "Due now") // 30 seconds
    #expect(formatDueIn(msUntilDue: -30_000) == "Due now") // -30 seconds
}

@Test func formatDueIn_positiveMs() {
    #expect(formatDueIn(msUntilDue: 45 * 60_000) == "Due in 45m")
    #expect(formatDueIn(msUntilDue: 2 * 60 * 60_000 + 15 * 60_000) == "Due in 2h 15m")
    #expect(formatDueIn(msUntilDue: 3 * 60 * 60_000) == "Due in 3h")
}

@Test func formatDueIn_negativeMs() {
    #expect(formatDueIn(msUntilDue: -45 * 60_000) == "Overdue 45m")
    #expect(formatDueIn(msUntilDue: -2 * 60 * 60_000 - 15 * 60_000) == "Overdue 2h 15m")
    #expect(formatDueIn(msUntilDue: -1 * 60 * 60_000) == "Overdue 1h")
}

@Test func formatDueIn_exactlyOneMinute() {
    #expect(formatDueIn(msUntilDue: 60_000) == "Due in 1m")
    #expect(formatDueIn(msUntilDue: -60_000) == "Overdue 1m")
}

// MARK: - startOfDay (verbatim from time.test.ts)

@Test func startOfDay_returnsMidnightInGivenTimezone() {
    let result = startOfDay(d("2026-04-15T14:30:00Z"), timeZone: utc)
    #expect(result == d("2026-04-15T00:00:00Z"))
}

// MARK: - DST parity tests (ADDED in Task 3 — not present in the TS suite)
//
// America/New_York: spring-forward 2026-03-08 02:00→03:00, fall-back
// 2026-11-01 02:00→01:00. Values below were DISCOVERED by running Foundation,
// then PINNED.
//
// IMPORTANT — the "AGREE with the web" claim below applies ONLY to the two
// `wallClockToUTC` cases (spring-forward gap, fall-back ambiguous hour).
// Those were each cross-checked against the TS `localTimeOnDateToUtc`
// offset-subtraction result (schedule.ts:74-101), computed in Node, and
// Foundation and JS agree byte-for-byte on both.
//
// `startOfDay` is a DIFFERENT story: on DST-transition days it INTENTIONALLY
// DIVERGES from the web. The web's `startOfDay` (time.ts:168-194) samples the
// local UTC offset at *noon* and applies it uniformly, which is wrong exactly
// on the two days per year the offset changes:
//   - Spring 2026-03-08T17:00Z → web gives 2026-03-08T04:00:00Z (23:00 the
//     PRIOR day — wrong); Foundation gives 2026-03-08T05:00:00Z (00:00 EST —
//     correct local midnight).
//   - Fall 2026-11-01T17:00Z → web gives 2026-11-01T05:00:00Z (01:00 — wrong);
//     Foundation gives 2026-11-01T04:00:00Z (00:00 EDT — correct).
// Decision: keep Foundation's correct behavior. The pinned values below are
// Foundation's CORRECT local-midnight instants, not values that match the
// web's (buggy) output. See docs/PARITY-DIVERGENCES.md for the full writeup.

@Test func startOfDay_springForwardDay() {
    // 2026-03-08 is a 23-hour day in NYC. Local midnight is still well-defined.
    let noonUTC = d("2026-03-08T17:00:00Z") // ~13:00 EDT, i.e. midday on 03-08
    let sod = startOfDay(noonUTC, timeZone: nyc)
    #expect(localDateString(sod, timeZone: nyc) == "2026-03-08")
    // Local midnight 2026-03-08 00:00 is still EST (offset -5) = 05:00 UTC.
    // (The web's startOfDay wrongly returns 2026-03-08T04:00:00Z here.)
    #expect(sod == d("2026-03-08T05:00:00Z"))
}

@Test func startOfDay_fallBackDay() {
    // 2026-11-01 is a 25-hour day in NYC (clocks fall back 02:00→01:00).
    let afternoonUTC = d("2026-11-01T17:00:00Z") // ~13:00 EDT (pre-rollback), midday on 11-01
    let sod = startOfDay(afternoonUTC, timeZone: nyc)
    #expect(localDateString(sod, timeZone: nyc) == "2026-11-01")
    // Local midnight 2026-11-01 00:00 is still EDT (offset -4) = 04:00 UTC.
    // (The web's startOfDay wrongly returns 2026-11-01T05:00:00Z here.)
    #expect(sod == d("2026-11-01T04:00:00Z"))
}

@Test func wallClock_insideSpringForwardGap() {
    // 02:30 on 2026-03-08 does not exist (clocks jump 02:00→03:00).
    // PINNED: Foundation resolves the gap to 2026-03-08T07:30:00Z.
    // (07:30 UTC == 03:30 EDT == 02:30-interpreted-as-EST; the gap is exactly
    // one hour so both readings coincide.)
    // Cross-check: TS localTimeOnDateToUtc("2026-03-08","02:30",NY) == 2026-03-08T07:30:00.000Z.
    // → Foundation and JS AGREE.
    let d0 = wallClockToUTC(year: 2026, month: 3, day: 8, hour: 2, minute: 30, timeZone: nyc)
    #expect(ISO8601DateFormatter().string(from: d0) == "2026-03-08T07:30:00Z")
}

@Test func wallClock_fallBackAmbiguousHour() {
    // 01:30 on 2026-11-01 occurs twice (once EDT, once EST).
    // PINNED: Foundation picks the FIRST occurrence, 01:30 EDT = 2026-11-01T05:30:00Z.
    // Cross-check: TS localTimeOnDateToUtc("2026-11-01","01:30",NY) == 2026-11-01T05:30:00.000Z.
    // → Foundation and JS AGREE.
    let d0 = wallClockToUTC(year: 2026, month: 11, day: 1, hour: 1, minute: 30, timeZone: nyc)
    #expect(ISO8601DateFormatter().string(from: d0) == "2026-11-01T05:30:00Z")
}

// MARK: - jsRound (Task 3 helper; documents the JS Math.round contract later tasks rely on)

@Test func jsRound_halfUpTowardPositiveInfinity() {
    #expect(jsRound(2.5) == 3)
    #expect(jsRound(2.4) == 2)
    #expect(jsRound(-0.5) == 0) // JS: 0, not -1
    #expect(jsRound(-2.5) == -2) // JS: -2, not -3
    #expect(jsRound(0.5) == 1)
    #expect(jsRound(-1.5) == -1)
}

// MARK: - localDayOfWeek (Task 3 helper; 0=Sunday…6=Saturday)

@Test func localDayOfWeek_matchesJSGetDay() {
    // 2026-04-15 is a Wednesday.
    #expect(localDayOfWeek(d("2026-04-15T12:00:00Z"), timeZone: utc) == 3)
    // 2026-03-08 (spring-forward day) is a Sunday.
    #expect(localDayOfWeek(d("2026-03-08T17:00:00Z"), timeZone: nyc) == 0)
    // 2026-11-01 (fall-back day) is a Sunday.
    #expect(localDayOfWeek(d("2026-11-01T17:00:00Z"), timeZone: nyc) == 0)
}
