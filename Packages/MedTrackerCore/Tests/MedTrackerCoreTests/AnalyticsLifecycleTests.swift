import Foundation
@testable import MedTrackerCore
import Testing

// Ports `tests/unit/analytics-lifecycle.test.ts` (all cases, verbatim).

private func d(_ s: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: s)!
}

private let APR_15 = d("2026-04-15T00:00:00.000Z")
private let APR_25 = d("2026-04-25T00:00:00.000Z")
private let MAY_01 = d("2026-05-01T00:00:00.000Z")
private let MAY_15 = d("2026-05-15T00:00:00.000Z")

// MARK: - clampEffectiveDays (verbatim from analytics-lifecycle.test.ts)

@Test func clampEffectiveDays_returnsFullRangeWhenLifecycleFullyContainsIt() {
    #expect(clampEffectiveDays(rangeFrom: APR_15, rangeTo: MAY_01, startedAt: APR_15, endedAt: nil) == 16)
}

@Test func clampEffectiveDays_clampsLeftEdgeWhenMedStartedMidRange() {
    // Range is 16 days; med started 2026-04-25 -> 6 effective days.
    #expect(clampEffectiveDays(rangeFrom: APR_15, rangeTo: MAY_01, startedAt: APR_25, endedAt: nil) == 6)
}

@Test func clampEffectiveDays_clampsRightEdgeWhenMedEndedMidRange() {
    // Range is 16 days; med ended 2026-04-25 -> 10 effective days.
    #expect(clampEffectiveDays(rangeFrom: APR_15, rangeTo: MAY_01, startedAt: APR_15, endedAt: APR_25) == 10)
}

@Test func clampEffectiveDays_clampsBothEdgesWhenLifecycleIsInteriorToRange() {
    #expect(clampEffectiveDays(rangeFrom: APR_15, rangeTo: MAY_15, startedAt: APR_25, endedAt: MAY_01) == 6)
}

@Test func clampEffectiveDays_returnsZeroWhenMedStartedAfterRangeEnds() {
    #expect(clampEffectiveDays(rangeFrom: APR_15, rangeTo: MAY_01, startedAt: MAY_15, endedAt: nil) == 0)
}

@Test func clampEffectiveDays_returnsZeroWhenMedEndedBeforeRangeStarts() {
    #expect(clampEffectiveDays(rangeFrom: MAY_01, rangeTo: MAY_15, startedAt: APR_15, endedAt: APR_25) == 0)
}

@Test func clampEffectiveDays_treatsEndedAtNilAsStillActive() {
    #expect(clampEffectiveDays(rangeFrom: APR_15, rangeTo: MAY_01, startedAt: APR_15, endedAt: nil) == 16)
}

@Test func clampEffectiveDays_returnsZeroForAZeroWidthRange() {
    #expect(clampEffectiveDays(rangeFrom: APR_15, rangeTo: APR_15, startedAt: APR_15, endedAt: nil) == 0)
}

// MARK: - isActiveOn (verbatim from analytics-lifecycle.test.ts)

@Test func isActiveOn_isTrueWhenDateIsExactlyAtStartedAt() {
    #expect(isActiveOn(APR_25, startedAt: APR_25, endedAt: nil) == true)
}

@Test func isActiveOn_isFalseWhenDateIsBeforeStartedAt() {
    #expect(isActiveOn(APR_15, startedAt: APR_25, endedAt: nil) == false)
}

@Test func isActiveOn_isTrueWhenDateIsBetweenStartedAtAndEndedAt() {
    #expect(isActiveOn(APR_25, startedAt: APR_15, endedAt: MAY_01) == true)
}

@Test func isActiveOn_isFalseWhenDateIsAfterEndedAt() {
    #expect(isActiveOn(MAY_15, startedAt: APR_15, endedAt: MAY_01) == false)
}

@Test func isActiveOn_treatsEndedAtNilAsOpenOnTheRight() {
    #expect(isActiveOn(MAY_15, startedAt: APR_15, endedAt: nil) == true)
}

@Test func isActiveOn_isTrueAtTheExactEndedAtInstant() {
    #expect(isActiveOn(MAY_01, startedAt: APR_15, endedAt: MAY_01) == true)
}

// MARK: - regression: user-facing scenarios from the plan (verbatim)

@Test func regression_medAddedYesterday_todaysAdherenceDenominatorIs1DayNot30() {
    let today = d("2026-05-01T12:00:00.000Z")
    let thirtyDaysAgo = today.addingTimeInterval(-30 * 86_400)
    let yesterday = today.addingTimeInterval(-1 * 86_400)
    #expect(clampEffectiveDays(rangeFrom: thirtyDaysAgo, rangeTo: today, startedAt: yesterday, endedAt: nil) == 1)
}

@Test func regression_endedMed_daysAfterEndedAtDontDragAdherenceDown() {
    let today = d("2026-05-01T12:00:00.000Z")
    let thirtyDaysAgo = today.addingTimeInterval(-30 * 86_400)
    let fiveDaysAgo = today.addingTimeInterval(-5 * 86_400)
    // Med was active for the first 25 days of the 30-day window.
    #expect(clampEffectiveDays(rangeFrom: thirtyDaysAgo, rangeTo: today, startedAt: thirtyDaysAgo, endedAt: fiveDaysAgo) == 25)
}
