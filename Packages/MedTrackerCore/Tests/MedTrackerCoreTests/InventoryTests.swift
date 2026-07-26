import Foundation
@testable import MedTrackerCore
import Testing

// Ports `tests/unit/inventory.test.ts` (all cases), plus the
// `expectedPerDayForSchedules` describe block from `tests/unit/analytics.test.ts`
// (that function is implemented here, in Inventory.swift, per the Task 5
// interface list — Task 6/Analytics.swift should reuse `expectedPerDay(forSchedules:)`
// rather than reimplementing it), plus the `calculateDaysUntilRefill` describe
// block from `tests/unit/time.test.ts` — deferred to this task from Task 3
// per that task's report (comment at the top of `TimeTests.swift`).

// MARK: - Fixtures (mirror inventory.test.ts's intervalSchedule/fixedTimeSchedule/prnSchedule)

private func intervalSchedule(_ hours: Decimal) -> ScheduleRow {
    ScheduleRow(kind: .interval, intervalHours: hours)
}

private func fixedTimeSchedule(_ timeOfDay: String, daysOfWeek: [Int]? = nil) -> ScheduleRow {
    ScheduleRow(kind: .fixedTime, timeOfDay: timeOfDay, daysOfWeek: daysOfWeek)
}

private func prnSchedule() -> ScheduleRow {
    ScheduleRow(kind: .prn)
}

// MARK: - classifyRefillSeverity (verbatim from inventory.test.ts)

@Test func classifyRefillSeverity_returnsOkWhenNil() {
    #expect(classifyRefillSeverity(days: nil) == .ok)
}

@Test func classifyRefillSeverity_returnsCriticalAtOrBelow3Days() {
    #expect(classifyRefillSeverity(days: 0) == .critical)
    #expect(classifyRefillSeverity(days: 3) == .critical)
}

@Test func classifyRefillSeverity_returnsWarningBetween4And7Days() {
    #expect(classifyRefillSeverity(days: 4) == .warning)
    #expect(classifyRefillSeverity(days: 7) == .warning)
}

@Test func classifyRefillSeverity_returnsWatchBetween8And14Days() {
    #expect(classifyRefillSeverity(days: 8) == .watch)
    #expect(classifyRefillSeverity(days: 14) == .watch)
}

@Test func classifyRefillSeverity_returnsOkAbove14Days() {
    #expect(classifyRefillSeverity(days: 15) == .ok)
    #expect(classifyRefillSeverity(days: 100) == .ok)
}

// MARK: - dailyRateFor (verbatim from inventory.test.ts)

@Test func dailyRateFor_usesScheduleRateFor24hInterval() {
    let rate = dailyRateFor(
        scheduleRows: [intervalSchedule(24)],
        legacyScheduleType: "scheduled",
        legacyIntervalHours: 24,
        thirtyDayTakenQuantity: 0
    )
    #expect(rate == 1)
}

@Test func dailyRateFor_usesScheduleRateFor12hInterval() {
    let rate = dailyRateFor(
        scheduleRows: [intervalSchedule(12)],
        legacyScheduleType: "scheduled",
        legacyIntervalHours: 12,
        thirtyDayTakenQuantity: 0
    )
    #expect(rate == 2)
}

@Test func dailyRateFor_sumsMultipleFixedTimeSchedules() {
    let rate = dailyRateFor(
        scheduleRows: [fixedTimeSchedule("08:00"), fixedTimeSchedule("20:00")],
        legacyScheduleType: "scheduled",
        legacyIntervalHours: nil,
        thirtyDayTakenQuantity: 0
    )
    #expect(rate == 2)
}

@Test func dailyRateFor_scalesFixedTimeByDaysOfWeekWhenRestricted() {
    let rate = dailyRateFor(
        scheduleRows: [fixedTimeSchedule("08:00", daysOfWeek: [1, 2, 3])],
        legacyScheduleType: "scheduled",
        legacyIntervalHours: nil,
        thirtyDayTakenQuantity: 0
    )
    #expect(abs(rate - 3.0 / 7.0) < 0.0001)
}

@Test func dailyRateFor_fallsBackToHistoricalAvgForPrnOnlySchedules() {
    let rate = dailyRateFor(
        scheduleRows: [prnSchedule()],
        legacyScheduleType: "as_needed",
        legacyIntervalHours: nil,
        thirtyDayTakenQuantity: 30
    )
    #expect(rate == 1)
}

@Test func dailyRateFor_fallsBackToLegacyIntervalColumnWhenNoScheduleRows() {
    let rate = dailyRateFor(
        scheduleRows: [],
        legacyScheduleType: "scheduled",
        legacyIntervalHours: 24,
        thirtyDayTakenQuantity: 0
    )
    #expect(rate == 1)
}

@Test func dailyRateFor_fallsBackTo30DayAverageForLegacyAsNeeded() {
    let rate = dailyRateFor(
        scheduleRows: [],
        legacyScheduleType: "as_needed",
        legacyIntervalHours: nil,
        thirtyDayTakenQuantity: 60
    )
    #expect(rate == 2)
}

// MARK: - daysUntilRefill (verbatim from inventory.test.ts)

@Test func daysUntilRefill_60StockAt1PerDayIs60Days() {
    #expect(daysUntilRefill(inventoryCount: 60, dailyRate: 1) == 60)
}

@Test func daysUntilRefill_10StockAt2PerDayIs5Days() {
    #expect(daysUntilRefill(inventoryCount: 10, dailyRate: 2) == 5)
}

@Test func daysUntilRefill_returnsNilWhenInventoryIsNil() {
    #expect(daysUntilRefill(inventoryCount: nil, dailyRate: 1) == nil)
}

@Test func daysUntilRefill_returnsNilWhenDailyRateIsZero() {
    #expect(daysUntilRefill(inventoryCount: 20, dailyRate: 0) == nil)
}

@Test func daysUntilRefill_roundsDownOnPartialDays() {
    #expect(daysUntilRefill(inventoryCount: 7, dailyRate: 2) == 3)
}

// MARK: - integration: scheduled vs PRN refill scenarios (verbatim from inventory.test.ts)

@Test func integration_scheduledMedStock60Interval24hReports60Days() {
    let rate = dailyRateFor(
        scheduleRows: [intervalSchedule(24)],
        legacyScheduleType: "scheduled",
        legacyIntervalHours: 24,
        thirtyDayTakenQuantity: 0
    )
    #expect(daysUntilRefill(inventoryCount: 60, dailyRate: rate) == 60)
}

@Test func integration_scheduledMedStock10Interval12hReports5Days() {
    let rate = dailyRateFor(
        scheduleRows: [intervalSchedule(12)],
        legacyScheduleType: "scheduled",
        legacyIntervalHours: 12,
        thirtyDayTakenQuantity: 0
    )
    #expect(daysUntilRefill(inventoryCount: 10, dailyRate: rate) == 5)
}

@Test func integration_prnMedStock15With30DosesIn30DaysReports15Days() {
    let rate = dailyRateFor(
        scheduleRows: [prnSchedule()],
        legacyScheduleType: "as_needed",
        legacyIntervalHours: nil,
        thirtyDayTakenQuantity: 30
    )
    #expect(daysUntilRefill(inventoryCount: 15, dailyRate: rate) == 15)
}

@Test func integration_prnMedWithNoHistoricalDosesReturnsNil() {
    let rate = dailyRateFor(
        scheduleRows: [prnSchedule()],
        legacyScheduleType: "as_needed",
        legacyIntervalHours: nil,
        thirtyDayTakenQuantity: 0
    )
    #expect(daysUntilRefill(inventoryCount: 15, dailyRate: rate) == nil)
}

// MARK: - expectedPerDay(forSchedules:) (verbatim from analytics.test.ts's
// `expectedPerDayForSchedules` block — that TS function is implemented here,
// in Inventory.swift, since `dailyRateFor` depends on it directly)

@Test func expectedPerDay_returnsZeroForEmptyScheduleList() {
    #expect(expectedPerDay(forSchedules: []) == 0)
}

@Test func expectedPerDay_treatsPrnRowAsZeroDosesPerDay() {
    #expect(expectedPerDay(forSchedules: [prnSchedule()]) == 0)
}

@Test func expectedPerDay_computes24OverIntervalHoursForIntervalRow() {
    let rate = expectedPerDay(forSchedules: [intervalSchedule(8)])
    #expect(abs(rate - 3.0) < 0.00001)
}

@Test func expectedPerDay_ignoresIntervalRowWithNonPositiveInterval() {
    #expect(expectedPerDay(forSchedules: [intervalSchedule(0)]) == 0)
}

@Test func expectedPerDay_countsUnrestrictedFixedTimeRowAsOneDosePerDay() {
    #expect(expectedPerDay(forSchedules: [fixedTimeSchedule("09:00")]) == 1)
}

@Test func expectedPerDay_scalesFixedTimeRowByDaysOfWeekLengthOver7() {
    let rate = expectedPerDay(forSchedules: [fixedTimeSchedule("09:00", daysOfWeek: [1, 3, 5])])
    #expect(abs(rate - 3.0 / 7.0) < 0.00001)
}

@Test func expectedPerDay_sumsContributionsFromHeterogeneousScheduleRows() {
    let total = expectedPerDay(forSchedules: [
        intervalSchedule(12),
        fixedTimeSchedule("20:00"),
        prnSchedule(),
    ])
    #expect(abs(total - 3.0) < 0.00001)
}

// MARK: - calculateDaysUntilRefill (legacy list-view path; verbatim from
// time.test.ts's `calculateDaysUntilRefill` block — deferred here from Task 3)

@Test func calculateDaysUntilRefill_calculatesDaysFromInventoryAndAverageConsumption() {
    #expect(calculateDaysUntilRefill(inventoryCount: 60, avgDailyConsumption: 2) == 30)
}

@Test func calculateDaysUntilRefill_floorsPartialDays() {
    #expect(calculateDaysUntilRefill(inventoryCount: 10, avgDailyConsumption: 3) == 3)
}

@Test func calculateDaysUntilRefill_returnsNilWhenInventoryIsNil() {
    #expect(calculateDaysUntilRefill(inventoryCount: nil, avgDailyConsumption: 2) == nil)
}

@Test func calculateDaysUntilRefill_returnsNilWhenConsumptionIsZero() {
    #expect(calculateDaysUntilRefill(inventoryCount: 30, avgDailyConsumption: 0) == nil)
}

@Test func calculateDaysUntilRefill_returnsNilWhenConsumptionIsNegative() {
    #expect(calculateDaysUntilRefill(inventoryCount: 30, avgDailyConsumption: -1) == nil)
}

@Test func calculateDaysUntilRefill_returnsZeroWhenInventoryIsLessThanDailyConsumption() {
    #expect(calculateDaysUntilRefill(inventoryCount: 1, avgDailyConsumption: 5) == 0)
}

@Test func calculateDaysUntilRefill_usesScheduleForScheduledMedsEvenWithNoDoseHistory() {
    let days = calculateDaysUntilRefill(
        inventoryCount: 60,
        avgDailyConsumption: 0,
        scheduleType: "scheduled",
        scheduleIntervalHours: 24
    )
    #expect(days == 60)
}

// The TS case "accepts numeric-string interval (Drizzle numeric column)"
// doesn't have a Swift analogue: `scheduleIntervalHours` is typed `Decimal?`
// here (per the Global Constraints — Drizzle's numeric-as-string is already
// converted at the repository boundary), so there's no string to parse.
// Passing the same Decimal(24) exercises the same code path as the
// "no dose history" case above; kept as a separate test only to document
// that this TS case collapses into it rather than silently dropping it.
@Test func calculateDaysUntilRefill_numericIntervalMatchesStringIntervalCase() {
    let days = calculateDaysUntilRefill(
        inventoryCount: 60,
        avgDailyConsumption: 0,
        scheduleType: "scheduled",
        scheduleIntervalHours: 24
    )
    #expect(days == 60)
}

@Test func calculateDaysUntilRefill_scheduledRateTakesPrecedenceOverHistoricalAvg() {
    let days = calculateDaysUntilRefill(
        inventoryCount: 60,
        avgDailyConsumption: 2,
        scheduleType: "scheduled",
        scheduleIntervalHours: 24
    )
    #expect(days == 60)
}

@Test func calculateDaysUntilRefill_fallsBackToHistoricalAvgForAsNeededMeds() {
    let days = calculateDaysUntilRefill(
        inventoryCount: 60,
        avgDailyConsumption: 2,
        scheduleType: "as_needed",
        scheduleIntervalHours: nil
    )
    #expect(days == 30)
}

@Test func calculateDaysUntilRefill_returnsNilForAsNeededMedWithNoHistory() {
    let days = calculateDaysUntilRefill(
        inventoryCount: 60,
        avgDailyConsumption: 0,
        scheduleType: "as_needed",
        scheduleIntervalHours: nil
    )
    #expect(days == nil)
}

@Test func calculateDaysUntilRefill_fallsBackToHistoricalAvgWhenScheduledButIntervalIsMissing() {
    let days = calculateDaysUntilRefill(
        inventoryCount: 60,
        avgDailyConsumption: 2,
        scheduleType: "scheduled",
        scheduleIntervalHours: nil
    )
    #expect(days == 30)
}

@Test func calculateDaysUntilRefill_supportsSubDailySchedules8hIntervalIs3PerDay() {
    let days = calculateDaysUntilRefill(
        inventoryCount: 30,
        avgDailyConsumption: 0,
        scheduleType: "scheduled",
        scheduleIntervalHours: 8
    )
    #expect(days == 10)
}
