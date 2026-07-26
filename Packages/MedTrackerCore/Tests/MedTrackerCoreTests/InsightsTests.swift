import Foundation
@testable import MedTrackerCore
import Testing

// Transcribes the `describe("buildInsights", ...)` block from
// `tests/unit/analytics.test.ts:137-283`, plus one additional case (at the
// bottom) asserting the em dash literal, which the TS suite only checks
// indirectly (via `toContain`/`toMatch` on substrings that don't include the
// dash itself).

/// Mirrors the TS test file's `baseInputs` fixture (`analytics.test.ts:16-28`)
/// — every field defaulted to empty/zero, with named-parameter overrides
/// standing in for JS's `{ ...baseInputs, X }` spread syntax.
private func makeInputs(
    totalDoses: Int = 0,
    prevTotalDoses: Int = 0,
    avgAdherence: Double = 0,
    prevAvgAdherence: Double = 0,
    medStats: [MedAdherenceStat] = [],
    dayOfWeek: [DayOfWeekCount] = [],
    hourly: [HourCount] = [],
    sideEffectsCount: Int = 0,
    topSideEffect: String? = nil,
    refillCriticalCount: Int = 0,
    streak: Int = 0
) -> InsightInputs {
    InsightInputs(
        totalDoses: totalDoses,
        prevTotalDoses: prevTotalDoses,
        avgAdherence: avgAdherence,
        prevAvgAdherence: prevAvgAdherence,
        medStats: medStats,
        dayOfWeek: dayOfWeek,
        hourly: hourly,
        sideEffectsCount: sideEffectsCount,
        topSideEffect: topSideEffect,
        refillCriticalCount: refillCriticalCount,
        streak: streak
    )
}

@Test func buildInsights_returnsEmptyArrayWhenThereIsNoData() {
    #expect(buildInsights(makeInputs()) == [])
}

@Test func buildInsights_emitsAdherenceTrendWhenPreviousDataExistsAndDeltaExceeds5() {
    let insights = buildInsights(makeInputs(
        avgAdherence: 80,
        prevAvgAdherence: 65,
        medStats: [
            MedAdherenceStat(medicationName: "A", adherence: 80, expectedTotal: 30),
            MedAdherenceStat(medicationName: "B", adherence: 80, expectedTotal: 30),
        ]
    ))
    let trend = insights.first { $0.id == "adherence-trend" }
    #expect(trend?.severity == .positive)
    #expect(trend?.text == "Adherence improved 15% vs. previous period")
}

@Test func buildInsights_doesNotEmitAdherenceTrendWhenDeltaIsBelow5() {
    let insights = buildInsights(makeInputs(
        avgAdherence: 80,
        prevAvgAdherence: 78,
        medStats: [
            MedAdherenceStat(medicationName: "A", adherence: 80, expectedTotal: 30),
            MedAdherenceStat(medicationName: "B", adherence: 80, expectedTotal: 30),
        ]
    ))
    #expect(insights.first { $0.id == "adherence-trend" } == nil)
}

@Test func buildInsights_emitsHighestAndLowestAdherenceInsightsWhen2PlusMedsWithData() {
    let insights = buildInsights(makeInputs(medStats: [
        MedAdherenceStat(medicationName: "Best", adherence: 95, expectedTotal: 30),
        MedAdherenceStat(medicationName: "Worst", adherence: 50, expectedTotal: 30),
    ]))
    #expect(insights.first { $0.id == "highest-adherence-med" }?.text.contains("Best") == true)
    #expect(insights.first { $0.id == "lowest-adherence-med" }?.text.contains("Worst") == true)
}

@Test func buildInsights_doesNotEmitLowestInsightWhenBottomAdherenceIsHealthy() {
    let insights = buildInsights(makeInputs(medStats: [
        MedAdherenceStat(medicationName: "A", adherence: 95, expectedTotal: 30),
        MedAdherenceStat(medicationName: "B", adherence: 90, expectedTotal: 30),
    ]))
    #expect(insights.first { $0.id == "lowest-adherence-med" } == nil)
}

@Test func buildInsights_emitsPeakHourWhenOneHourHolds30PercentPlusOfDoses() {
    let insights = buildInsights(makeInputs(hourly: [
        HourCount(hour: 8, count: 5),
        HourCount(hour: 12, count: 1),
        HourCount(hour: 20, count: 1),
    ]))
    #expect(insights.first { $0.id == "peak-hour" }?.text.contains("08:00") == true)
}

@Test func buildInsights_emitsStreakWhenStreakIsAtLeast3() {
    let insights = buildInsights(makeInputs(streak: 7))
    #expect(insights.first { $0.id == "streak" }?.text.contains("7 days") == true)
}

@Test func buildInsights_emitsWorstDayWhenOneDoWHasNotablyFewerDosesThanTheAverage() {
    let insights = buildInsights(makeInputs(dayOfWeek: [
        DayOfWeekCount(dayOfWeek: 0, count: 5), // Sun
        DayOfWeekCount(dayOfWeek: 1, count: 5), // Mon
        DayOfWeekCount(dayOfWeek: 2, count: 5), // Tue
        DayOfWeekCount(dayOfWeek: 3, count: 5), // Wed
        DayOfWeekCount(dayOfWeek: 4, count: 5), // Thu
        DayOfWeekCount(dayOfWeek: 5, count: 5), // Fri
        DayOfWeekCount(dayOfWeek: 6, count: 0), // Sat — well below 70% of avg
    ]))
    let worstDay = insights.first { $0.id == "worst-day" }
    #expect(worstDay != nil)
    #expect(worstDay?.text.contains("Saturday") == true)
}

@Test func buildInsights_doesNotEmitWorstDayWhenDistributionIsRoughlyEven() {
    let insights = buildInsights(makeInputs(
        dayOfWeek: (0 ..< 7).map { DayOfWeekCount(dayOfWeek: $0, count: 4) }
    ))
    #expect(insights.first { $0.id == "worst-day" } == nil)
}

@Test func buildInsights_emitsRefillWarningWhenAtLeastOneMedNeedsRefilling() {
    let single = buildInsights(makeInputs(refillCriticalCount: 1))
    let sInsight = single.first { $0.id == "refill-warning" }
    #expect(sInsight != nil)
    #expect(sInsight?.severity == .warning)
    #expect(sInsight?.text == "1 medication needs a refill within 7 days")

    let multiple = buildInsights(makeInputs(refillCriticalCount: 3))
    let mInsight = multiple.first { $0.id == "refill-warning" }
    #expect(mInsight?.text == "3 medications need a refill within 7 days")
}

@Test func buildInsights_doesNotEmitRefillWarningWhenRefillCriticalCountIs0() {
    let insights = buildInsights(makeInputs(refillCriticalCount: 0))
    #expect(insights.first { $0.id == "refill-warning" } == nil)
}

@Test func buildInsights_emitsSideEffectsInsightWhenCountIsAtLeast3() {
    let insights = buildInsights(makeInputs(sideEffectsCount: 5, topSideEffect: "Drowsiness"))
    #expect(insights.first { $0.id == "side-effects" }?.text.contains("Drowsiness") == true)
}

@Test func buildInsights_ordersWarningsBeforePositiveBeforeInfoAndSlicesTo5() {
    let insights = buildInsights(makeInputs(
        avgAdherence: 60,
        prevAvgAdherence: 80,
        medStats: [
            MedAdherenceStat(medicationName: "A", adherence: 95, expectedTotal: 30),
            MedAdherenceStat(medicationName: "B", adherence: 50, expectedTotal: 30),
        ],
        hourly: [
            HourCount(hour: 8, count: 5),
            HourCount(hour: 12, count: 1),
        ],
        sideEffectsCount: 4,
        topSideEffect: "Nausea",
        refillCriticalCount: 2,
        streak: 5
    ))
    #expect(insights.count <= 5)
    #expect(insights.first?.severity == .warning)
}

// MARK: - Exact-string / em-dash parity (additional coverage beyond the TS suite)

/// The TS suite only checks the side-effects text via `toContain("Drowsiness")`
/// substring matches, never asserting the separator character itself. Parity
/// with `analytics.ts:529` requires an em dash (U+2014), not a hyphen
/// (U+002D) — this pins the exact string end to end, including the dash.
@Test func buildInsights_sideEffectsTextUsesEmDashNotHyphen() {
    let insights = buildInsights(makeInputs(sideEffectsCount: 5, topSideEffect: "Drowsiness"))
    let text = insights.first { $0.id == "side-effects" }?.text
    #expect(text == "5 side effects logged \u{2014} most common: Drowsiness")
    #expect(text?.contains("\u{2014}") == true)
    #expect(text?.contains("-") == false)
}

@Test func buildInsights_highestAdherenceMedTextIsExact() {
    let insights = buildInsights(makeInputs(medStats: [
        MedAdherenceStat(medicationName: "Best", adherence: 95, expectedTotal: 30),
        MedAdherenceStat(medicationName: "Worst", adherence: 50, expectedTotal: 30),
    ]))
    #expect(insights.first { $0.id == "highest-adherence-med" }?.text == "Highest adherence: Best (95%)")
    #expect(insights.first { $0.id == "lowest-adherence-med" }?.text == "Lowest adherence: Worst (50%)")
}

@Test func buildInsights_peakHourTextIsExactWithZeroPaddedHour() {
    let insights = buildInsights(makeInputs(hourly: [
        HourCount(hour: 8, count: 5),
        HourCount(hour: 12, count: 1),
        HourCount(hour: 20, count: 1),
    ]))
    #expect(insights.first { $0.id == "peak-hour" }?.text == "Most consistent dosing time is 08:00")
}

@Test func buildInsights_worstDayTextIsExact() {
    let insights = buildInsights(makeInputs(dayOfWeek: [
        DayOfWeekCount(dayOfWeek: 0, count: 5),
        DayOfWeekCount(dayOfWeek: 1, count: 5),
        DayOfWeekCount(dayOfWeek: 2, count: 5),
        DayOfWeekCount(dayOfWeek: 3, count: 5),
        DayOfWeekCount(dayOfWeek: 4, count: 5),
        DayOfWeekCount(dayOfWeek: 5, count: 5),
        DayOfWeekCount(dayOfWeek: 6, count: 0),
    ]))
    #expect(insights.first { $0.id == "worst-day" }?.text == "Fewest doses on Saturday")
}

@Test func buildInsights_streakTextIsExact() {
    let insights = buildInsights(makeInputs(streak: 7))
    #expect(insights.first { $0.id == "streak" }?.text == "Current streak: 7 days")
}
