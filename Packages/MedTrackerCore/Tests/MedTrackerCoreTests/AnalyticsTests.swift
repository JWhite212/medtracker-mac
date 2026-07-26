import Foundation
@testable import MedTrackerCore
import Testing

// Ports the `calculateStreak`, `calculateAdherence`/`calculateOveruse`
// (→ `adherencePercent`/`overusePercent`), and `calculateTrend` describe
// blocks from `tests/unit/analytics.test.ts`. Deliberately NOT ported here:
//   - `buildInsights` — Task 7 (Insights.swift / InsightsTests.swift).
//   - `expectedPerDayForSchedules` — already transcribed in InventoryTests.swift
//     against `expectedPerDay(forSchedules:)` (Task 5), since `dailyRateFor`
//     depends on it directly. Not duplicated here.
//   - Every DB-query function in analytics.ts (`getPerMedicationStats`,
//     `getDailyAdherenceSeries`, `getDoseStatusBreakdown`, distribution
//     helpers) — those need a database and belong to a later phase.
//
// `calculateStreak`'s TS test cases build their fixture dates off `new
// Date()` (real wall-clock "now"), because the TS function resolves "today"
// internally via `Intl.DateTimeFormat`. The Swift port takes `today` as an
// explicit parameter instead (see Analytics.swift's file header), so the
// two "real wall-clock" cases below are transcribed against a fixed anchor
// date rather than `Date()` — the day-gap arithmetic under test is
// unchanged, only the "what is today" plumbing differs, per this task's
// specified interface.

// MARK: - calculateStreak (verbatim gap logic from analytics.test.ts, fixed anchor per the `today` param)

@Test func calculateStreak_returnsZeroForEmptyDates() {
    #expect(calculateStreak(dateStringsNewestFirst: [], today: "2026-05-01") == 0)
}

@Test func calculateStreak_countsConsecutiveDaysEndingToday() {
    let dates = ["2026-05-01", "2026-04-30", "2026-04-29"]
    #expect(calculateStreak(dateStringsNewestFirst: dates, today: "2026-05-01") == 3)
}

@Test func calculateStreak_breaksOnGap() {
    let dates = ["2026-05-01", "2026-04-28"]
    #expect(calculateStreak(dateStringsNewestFirst: dates, today: "2026-05-01") == 1)
}

// Additional case (not in the TS suite, which resolves "today" internally
// and so never exercises this branch with a mismatched first entry): the
// `dates[0] != today` guard, now directly reachable since `today` is an
// explicit parameter here.
@Test func calculateStreak_returnsZeroWhenFirstDateIsNotToday() {
    let dates = ["2026-04-30", "2026-04-29"]
    #expect(calculateStreak(dateStringsNewestFirst: dates, today: "2026-05-01") == 0)
}

// MARK: - adherencePercent (verbatim from analytics.test.ts's calculateAdherence block)

@Test func adherencePercent_returns100WhenAllDosesTaken() {
    #expect(adherencePercent(taken: 7, expected: 7) == 100)
}

@Test func adherencePercent_returnsCorrectPercentage() {
    // 5/7 = 71.42857...% -> rounds to 71.4
    #expect(abs(adherencePercent(taken: 5, expected: 7) - 71.4) < 0.001)
}

@Test func adherencePercent_returnsZeroForNoExpectedDoses() {
    #expect(adherencePercent(taken: 0, expected: 0) == 0)
}

@Test func adherencePercent_capsAt100WhenTakenExceedsExpected() {
    #expect(adherencePercent(taken: 10, expected: 7) == 100)
    #expect(adherencePercent(taken: 20, expected: 1) == 100)
}

// MARK: - overusePercent (verbatim from analytics.test.ts's calculateOveruse block)

@Test func overusePercent_isZeroWhenTakenDoesNotExceedExpected() {
    #expect(overusePercent(taken: 0, expected: 0) == 0)
    #expect(overusePercent(taken: 5, expected: 7) == 0)
    #expect(overusePercent(taken: 7, expected: 7) == 0)
}

@Test func overusePercent_reportsOverflowAsPercentageAbove100PercentAdherence() {
    // 10 taken / 7 expected = 142.9% adherence -> 42.9% overuse
    #expect(abs(overusePercent(taken: 10, expected: 7) - 42.9) < 0.001)
    // 14 / 7 = 200% adherence -> 100% overuse
    #expect(overusePercent(taken: 14, expected: 7) == 100)
}

@Test func overusePercent_returnsZeroWhenExpectedIsZero() {
    #expect(overusePercent(taken: 5, expected: 0) == 0)
}

// MARK: - calculateTrend (verbatim from analytics.test.ts)

@Test func calculateTrend_returnsUpWhenCurrentExceedsPrevious() {
    let result = calculateTrend(current: 100, previous: 80)
    #expect(result.direction == .up)
    #expect(result.percent == 25)
}

@Test func calculateTrend_returnsDownWhenCurrentIsLessThanPrevious() {
    let result = calculateTrend(current: 60, previous: 80)
    #expect(result.direction == .down)
    #expect(result.percent == 25)
}

@Test func calculateTrend_returnsFlatWhenBothAreZero() {
    let result = calculateTrend(current: 0, previous: 0)
    #expect(result.direction == .flat)
    #expect(result.percent == 0)
}

@Test func calculateTrend_returnsFlatWhenValuesAreEqual() {
    let result = calculateTrend(current: 50, previous: 50)
    #expect(result.direction == .flat)
    #expect(result.percent == 0)
}

@Test func calculateTrend_returnsUp100PercentWhenPreviousIsZeroAndCurrentIsPositive() {
    let result = calculateTrend(current: 10, previous: 0)
    #expect(result.direction == .up)
    #expect(result.percent == 100)
}

@Test func calculateTrend_returnsDown100PercentWhenCurrentDropsToZero() {
    let result = calculateTrend(current: 0, previous: 50)
    #expect(result.direction == .down)
    #expect(result.percent == 100)
}

@Test func calculateTrend_roundsPercentToNearestInteger() {
    let result = calculateTrend(current: 10, previous: 3)
    #expect(result.direction == .up)
    #expect(result.percent == 233)
}
