import Foundation
import Testing
@testable import MedTrackerCore

// Ports `tests/unit/schedule.test.ts` (all cases) plus the `computeTimingStatus`
// cases from `tests/unit/time.test.ts` (deferred to this task per Task 3's
// report, since `computeTimingStatus` lives in `Schedule.swift`). ADDS DST
// slot cases at the bottom — the new safety net that does not exist in the
// TS suite (see brief step 2).

private let isoFormatter = ISO8601DateFormatter()
private let isoFormatterWithFractionalSeconds: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

/// Parses an ISO-8601 instant, accepting both plain-seconds
/// (`2026-04-16T00:00:00Z`) and fractional-seconds
/// (`2026-04-16T00:00:00.000Z`, the shape `Date#toISOString()` produces on
/// the TS side) forms — the default `ISO8601DateFormatter` only parses the
/// former and returns nil (crashing a force-unwrap) on the latter.
private func d(_ s: String) -> Date {
    isoFormatter.date(from: s) ?? isoFormatterWithFractionalSeconds.date(from: s)!
}

private let utc = TimeZone(identifier: "UTC")!
private let nyc = TimeZone(identifier: "America/New_York")!

// MARK: - Fixtures (mirror schedule.test.ts's makeMed/makeIntervalSchedule/etc.,
// trimmed to the lean Swift model — display-only fields dropped.)

private func intervalSchedule(_ hours: Decimal) -> ScheduleRow {
    ScheduleRow(kind: .interval, intervalHours: hours)
}

private func fixedTimeSchedule(_ timeOfDay: String, daysOfWeek: [Int]? = nil) -> ScheduleRow {
    ScheduleRow(kind: .fixedTime, timeOfDay: timeOfDay, daysOfWeek: daysOfWeek)
}

private func prnSchedule() -> ScheduleRow {
    ScheduleRow(kind: .prn)
}

private func dose(
    id: String = "dose-1",
    medicationId: String = "med-1",
    takenAt: Date,
    status: DoseStatus = .taken
) -> DoseEvent {
    DoseEvent(id: id, medicationId: medicationId, takenAt: takenAt, status: status)
}

/// Flattens the per-medication result dict into a single slot array sorted
/// ascending by `expectedTime`, matching the shape of the TS tests' flat
/// `slots` array (the TS `computeScheduleSlots` returns `ScheduleSlot[]`
/// directly; the Swift port groups by medication id, so tests re-flatten).
private func flattenSorted(_ result: [String: [ScheduleSlot]]) -> [ScheduleSlot] {
    result.values.flatMap { $0 }.sorted { $0.expectedTime < $1.expectedTime }
}

// MARK: - classifyHour (verbatim from schedule.test.ts)

@Test func classifyHour_morning() {
    #expect(classifyHour(5) == .morning)
    #expect(classifyHour(11) == .morning)
}

@Test func classifyHour_afternoon() {
    #expect(classifyHour(12) == .afternoon)
    #expect(classifyHour(16) == .afternoon)
}

@Test func classifyHour_evening() {
    #expect(classifyHour(17) == .evening)
    #expect(classifyHour(20) == .evening)
}

@Test func classifyHour_night() {
    #expect(classifyHour(21) == .night)
    #expect(classifyHour(0) == .night)
    #expect(classifyHour(4) == .night)
}

// MARK: - computeScheduleSlots — interval kind (verbatim from schedule.test.ts)

private let intervalDayStart = d("2026-04-16T00:00:00Z")
private let intervalDayEnd = d("2026-04-17T00:00:00Z")

@Test func interval_8h_noPriorDoses_produces3Slots() {
    let now = d("2026-04-16T10:00:00Z")
    let result = computeScheduleSlots(
        medications: ["med-1"],
        schedulesByMedId: ["med-1": [intervalSchedule(8)]],
        todaysDoses: [],
        lastTakenByMed: [:],
        dayStart: intervalDayStart, dayEnd: intervalDayEnd, timeZone: utc, now: now
    )
    let slots = flattenSorted(result)
    #expect(slots.count == 3)
    #expect(slots[0].expectedTime == d("2026-04-16T00:00:00.000Z"))
    #expect(slots[1].expectedTime == d("2026-04-16T08:00:00.000Z"))
    #expect(slots[2].expectedTime == d("2026-04-16T16:00:00.000Z"))
}

@Test func interval_anchorsFromLastDoseBeforeToday() {
    let now = d("2026-04-16T10:00:00Z")
    let lastTaken = ["med-1": d("2026-04-15T22:00:00Z")]
    let result = computeScheduleSlots(
        medications: ["med-1"],
        schedulesByMedId: ["med-1": [intervalSchedule(8)]],
        todaysDoses: [],
        lastTakenByMed: lastTaken,
        dayStart: intervalDayStart, dayEnd: intervalDayEnd, timeZone: utc, now: now
    )
    let slots = flattenSorted(result)
    #expect(slots.count == 3)
    #expect(slots[0].expectedTime == d("2026-04-16T06:00:00.000Z"))
    #expect(slots[1].expectedTime == d("2026-04-16T14:00:00.000Z"))
    #expect(slots[2].expectedTime == d("2026-04-16T22:00:00.000Z"))
}

@Test func interval_marksSlotTakenWhenDoseMatchesWithin1Hour() {
    let now = d("2026-04-16T10:00:00Z")
    let lastTaken = ["med-1": d("2026-04-15T22:00:00Z")]
    let takenDose = dose(takenAt: d("2026-04-16T06:30:00Z"))
    let result = computeScheduleSlots(
        medications: ["med-1"],
        schedulesByMedId: ["med-1": [intervalSchedule(8)]],
        todaysDoses: [takenDose],
        lastTakenByMed: lastTaken,
        dayStart: intervalDayStart, dayEnd: intervalDayEnd, timeZone: utc, now: now
    )
    let slots = flattenSorted(result)
    #expect(slots[0].status == .taken)
    #expect(slots[0].matchedDoseId == "dose-1")
}

@Test func interval_marksPastUnmatchedSlotsAsOverdue() {
    let now = d("2026-04-16T10:00:00Z")
    let lastTaken = ["med-1": d("2026-04-15T22:00:00Z")]
    let result = computeScheduleSlots(
        medications: ["med-1"],
        schedulesByMedId: ["med-1": [intervalSchedule(8)]],
        todaysDoses: [],
        lastTakenByMed: lastTaken,
        dayStart: intervalDayStart, dayEnd: intervalDayEnd, timeZone: utc, now: now
    )
    let slots = flattenSorted(result)
    #expect(slots[0].status == .overdue)
    #expect(slots[1].status == .upcoming)
    #expect(slots[2].status == .upcoming)
}

@Test func interval_marksSlotSkippedWhenMatchedDoseSkipped() {
    let now = d("2026-04-16T10:00:00Z")
    let lastTaken = ["med-1": d("2026-04-15T22:00:00Z")]
    let skip = dose(id: "dose-skip-1", takenAt: d("2026-04-16T06:30:00Z"), status: .skipped)
    let result = computeScheduleSlots(
        medications: ["med-1"],
        schedulesByMedId: ["med-1": [intervalSchedule(8)]],
        todaysDoses: [skip],
        lastTakenByMed: lastTaken,
        dayStart: intervalDayStart, dayEnd: intervalDayEnd, timeZone: utc, now: now
    )
    let slots = flattenSorted(result)
    #expect(slots[0].status == .skipped)
    #expect(slots[0].matchedDoseId == "dose-skip-1")
}

@Test func interval_marksSlotOverdueNotTakenWhenMatchedDoseMissed() {
    let now = d("2026-04-16T10:00:00Z")
    let lastTaken = ["med-1": d("2026-04-15T22:00:00Z")]
    let missed = dose(id: "dose-missed-1", takenAt: d("2026-04-16T06:30:00Z"), status: .missed)
    let result = computeScheduleSlots(
        medications: ["med-1"],
        schedulesByMedId: ["med-1": [intervalSchedule(8)]],
        todaysDoses: [missed],
        lastTakenByMed: lastTaken,
        dayStart: intervalDayStart, dayEnd: intervalDayEnd, timeZone: utc, now: now
    )
    let slots = flattenSorted(result)
    #expect(slots[0].status == .overdue)
    #expect(slots[0].matchedDoseId == "dose-missed-1")
}

@Test func interval_producesCorrectSlotCountForVariousIntervals() {
    let now = d("2026-04-16T01:00:00Z")

    let result6 = computeScheduleSlots(
        medications: ["med-1"], schedulesByMedId: ["med-1": [intervalSchedule(6)]],
        todaysDoses: [], lastTakenByMed: [:],
        dayStart: intervalDayStart, dayEnd: intervalDayEnd, timeZone: utc, now: now
    )
    #expect(flattenSorted(result6).count == 4)

    let result12 = computeScheduleSlots(
        medications: ["med-1"], schedulesByMedId: ["med-1": [intervalSchedule(12)]],
        todaysDoses: [], lastTakenByMed: [:],
        dayStart: intervalDayStart, dayEnd: intervalDayEnd, timeZone: utc, now: now
    )
    #expect(flattenSorted(result12).count == 2)

    let result24 = computeScheduleSlots(
        medications: ["med-1"], schedulesByMedId: ["med-1": [intervalSchedule(24)]],
        todaysDoses: [], lastTakenByMed: [:],
        dayStart: intervalDayStart, dayEnd: intervalDayEnd, timeZone: utc, now: now
    )
    #expect(flattenSorted(result24).count == 1)
}

// MARK: - computeScheduleSlots — fixed_time kind (verbatim from schedule.test.ts)

private let fixedDayStart = d("2026-04-16T00:00:00Z")
private let fixedDayEnd = d("2026-04-17T00:00:00Z")

@Test func fixedTime_producesOneSlotPerTimeOfDayRow() {
    let now = d("2026-04-16T01:00:00Z")
    let result = computeScheduleSlots(
        medications: ["med-1"],
        schedulesByMedId: ["med-1": [fixedTimeSchedule("08:00"), fixedTimeSchedule("20:00")]],
        todaysDoses: [], lastTakenByMed: [:],
        dayStart: fixedDayStart, dayEnd: fixedDayEnd, timeZone: utc, now: now
    )
    let slots = flattenSorted(result)
    #expect(slots.count == 2)
    #expect(slots[0].expectedTime == d("2026-04-16T08:00:00.000Z"))
    #expect(slots[1].expectedTime == d("2026-04-16T20:00:00.000Z"))
}

@Test func fixedTime_respectsDaysOfWeekFilter() {
    // 2026-04-16 is a Thursday (dow=4). Restrict to Mon/Wed/Fri (1,3,5).
    let now = d("2026-04-16T01:00:00Z")
    let result = computeScheduleSlots(
        medications: ["med-1"],
        schedulesByMedId: ["med-1": [fixedTimeSchedule("08:00", daysOfWeek: [1, 3, 5])]],
        todaysDoses: [], lastTakenByMed: [:],
        dayStart: fixedDayStart, dayEnd: fixedDayEnd, timeZone: utc, now: now
    )
    #expect(flattenSorted(result).isEmpty)
}

@Test func fixedTime_emitsSlotWhenDaysOfWeekAllowsLocalDay() {
    // Thursday = 4.
    let now = d("2026-04-16T01:00:00Z")
    let result = computeScheduleSlots(
        medications: ["med-1"],
        schedulesByMedId: ["med-1": [fixedTimeSchedule("08:00", daysOfWeek: [4])]],
        todaysDoses: [], lastTakenByMed: [:],
        dayStart: fixedDayStart, dayEnd: fixedDayEnd, timeZone: utc, now: now
    )
    #expect(flattenSorted(result).count == 1)
}

// MARK: - computeScheduleSlots — prn and mixed (verbatim from schedule.test.ts)

private let mixedDayStart = d("2026-04-16T00:00:00Z")
private let mixedDayEnd = d("2026-04-17T00:00:00Z")

@Test func prn_producesZeroSlots() {
    let now = d("2026-04-16T10:00:00Z")
    let result = computeScheduleSlots(
        medications: ["med-1"], schedulesByMedId: ["med-1": [prnSchedule()]],
        todaysDoses: [], lastTakenByMed: [:],
        dayStart: mixedDayStart, dayEnd: mixedDayEnd, timeZone: utc, now: now
    )
    #expect(flattenSorted(result).isEmpty)
}

@Test func medicationWithNoSchedules_producesZeroSlots() {
    let now = d("2026-04-16T10:00:00Z")
    let result = computeScheduleSlots(
        medications: ["med-1"], schedulesByMedId: [:],
        todaysDoses: [], lastTakenByMed: [:],
        dayStart: mixedDayStart, dayEnd: mixedDayEnd, timeZone: utc, now: now
    )
    #expect(flattenSorted(result).isEmpty)
}

@Test func multiSchedule_producesUnionDeduped() {
    let now = d("2026-04-16T01:00:00Z")
    let result = computeScheduleSlots(
        medications: ["med-1"],
        schedulesByMedId: ["med-1": [intervalSchedule(12), fixedTimeSchedule("08:00")]],
        todaysDoses: [], lastTakenByMed: [:],
        dayStart: mixedDayStart, dayEnd: mixedDayEnd, timeZone: utc, now: now
    )
    // Interval @ 12h with no prior dose: 00:00, 12:00. Fixed: 08:00. Total = 3 distinct instants.
    let times = flattenSorted(result).map(\.expectedTime)
    #expect(times == [
        d("2026-04-16T00:00:00.000Z"),
        d("2026-04-16T08:00:00.000Z"),
        d("2026-04-16T12:00:00.000Z"),
    ])
}

// MARK: - groupSlotsByTimeOfDay (verbatim from schedule.test.ts)

@Test func groupSlotsByTimeOfDay_groupsIntoCorrectBuckets() {
    let now = d("2026-04-16T01:00:00Z")
    let result = computeScheduleSlots(
        medications: ["med-1"], schedulesByMedId: ["med-1": [intervalSchedule(6)]],
        todaysDoses: [], lastTakenByMed: [:],
        dayStart: mixedDayStart, dayEnd: mixedDayEnd, timeZone: utc, now: now
    )
    let groups = groupSlotsByTimeOfDay(flattenSorted(result), timeZone: utc)
    let keys = groups.map(\.bucket)
    #expect(keys.contains(.night))
    #expect(keys.contains(.morning))
    #expect(keys.contains(.afternoon))
    #expect(keys.contains(.evening))
}

@Test func groupSlotsByTimeOfDay_omitsEmptyGroups() {
    let now = d("2026-04-16T01:00:00Z")
    let result = computeScheduleSlots(
        medications: ["med-1"], schedulesByMedId: ["med-1": [intervalSchedule(24)]],
        todaysDoses: [], lastTakenByMed: [:],
        dayStart: mixedDayStart, dayEnd: mixedDayEnd, timeZone: utc, now: now
    )
    let groups = groupSlotsByTimeOfDay(flattenSorted(result), timeZone: utc)
    #expect(groups.count == 1)
    #expect(groups[0].bucket == .night)
}

// MARK: - computeTimingStatus (transcribed from time.test.ts's `computeTimingStatus`
// block — deferred to this task per Task 3's report, since the function now
// lives in Schedule.swift.)

private let timingNow = d("2026-04-15T14:30:00Z")

@Test func computeTimingStatus_overdueWhenNeverTaken() {
    let result = computeTimingStatus(intervalHours: 8, lastEventAt: nil, now: timingNow)
    #expect(result.status == .overdue)
    #expect(result.minutesUntilDue == -1)
}

@Test func computeTimingStatus_okWhenMoreThan1HourAway() {
    // Last taken 1 hour ago, interval 8 hours => next due in 7 hours.
    let lastTaken = d("2026-04-15T13:30:00Z")
    let result = computeTimingStatus(intervalHours: 8, lastEventAt: lastTaken, now: timingNow)
    #expect(result.status == .ok)
    #expect(result.minutesUntilDue == 7 * 60)
}

@Test func computeTimingStatus_dueSoonWithin1Hour() {
    // Last taken 7.5 hours ago, interval 8 hours => next due in 30 min.
    let lastTaken = d("2026-04-15T07:00:00Z")
    let result = computeTimingStatus(intervalHours: 8, lastEventAt: lastTaken, now: timingNow)
    #expect(result.status == .dueSoon)
    #expect(result.minutesUntilDue == 30)
}

@Test func computeTimingStatus_dueNowWithin1Minute() {
    // Last taken exactly 8 hours ago => due right now.
    let lastTaken = d("2026-04-15T06:30:00Z")
    let result = computeTimingStatus(intervalHours: 8, lastEventAt: lastTaken, now: timingNow)
    #expect(result.status == .dueNow)
    #expect(result.minutesUntilDue == 0)
}

@Test func computeTimingStatus_overdueWhenPastDueByMoreThan1Minute() {
    // Last taken 9 hours ago, interval 8 hours => overdue by 1 hour.
    let lastTaken = d("2026-04-15T05:30:00Z")
    let result = computeTimingStatus(intervalHours: 8, lastEventAt: lastTaken, now: timingNow)
    #expect(result.status == .overdue)
    #expect(result.minutesUntilDue == -60)
}

@Test func computeTimingStatus_handlesFractionalIntervalHours() {
    // Interval 0.5h (30 min), last taken 20 min ago => due in 10 min.
    let lastTaken = d("2026-04-15T14:10:00Z")
    let result = computeTimingStatus(intervalHours: 0.5, lastEventAt: lastTaken, now: timingNow)
    #expect(result.status == .dueSoon)
    #expect(result.minutesUntilDue == 10)
}

// MARK: - DST slot cases (ADDED — not present in schedule.test.ts)
//
// America/New_York, 2026: spring-forward 03-08 02:00→03:00 (a 23h local day),
// fall-back 11-01 02:00→01:00 (a 25h local day). Both happen to be Sundays
// (localDayOfWeek == 0, pinned in TimeTests.swift), which lets the same two
// fixtures exercise both the fixed_time instant-resolution path and the
// daysOfWeek filter path.
//
// dayStart/dayEnd are built the way the app does elsewhere: local midnight
// (via `startOfDay`, pinned in TimeTests.swift) + 24h. Because the
// spring-forward day is only 23h long, this window actually extends 1h into
// the *next* local day (so the date-enumeration helper visits an extra
// candidate date); because the fall-back day is 25h long, the window falls
// 1h short of the next actual local midnight. Both are handled correctly by
// the per-instant `[dayStart, dayEnd)` range check in
// `expectedTimesForFixedTime` — verified below by asserting exactly one slot
// is produced in each case.

private let springForwardDayStart = startOfDay(d("2026-03-08T17:00:00Z"), timeZone: nyc) // 2026-03-08T05:00:00Z
private let springForwardDayEnd = springForwardDayStart.addingTimeInterval(24 * 3600)

private let fallBackDayStart = startOfDay(d("2026-11-01T17:00:00Z"), timeZone: nyc) // 2026-11-01T04:00:00Z
private let fallBackDayEnd = fallBackDayStart.addingTimeInterval(24 * 3600)

@Test func dstFixedTime_0800_springForward_singleSlot() {
    let result = computeScheduleSlots(
        medications: ["med-1"],
        schedulesByMedId: ["med-1": [fixedTimeSchedule("08:00")]],
        todaysDoses: [], lastTakenByMed: [:],
        dayStart: springForwardDayStart, dayEnd: springForwardDayEnd, timeZone: nyc,
        now: springForwardDayStart
    )
    let slots = flattenSorted(result)
    #expect(slots.count == 1)
    // 08:00 local on 03-08 is already past the 02:00→03:00 jump, so it's EDT (offset -4).
    #expect(slots[0].expectedTime == d("2026-03-08T12:00:00Z"))
}

@Test func dstFixedTime_0230_springForward_resolvesGapForward_singleSlot() {
    let result = computeScheduleSlots(
        medications: ["med-1"],
        schedulesByMedId: ["med-1": [fixedTimeSchedule("02:30")]],
        todaysDoses: [], lastTakenByMed: [:],
        dayStart: springForwardDayStart, dayEnd: springForwardDayEnd, timeZone: nyc,
        now: springForwardDayStart
    )
    let slots = flattenSorted(result)
    #expect(slots.count == 1)
    // 02:30 does not exist on 03-08 (clocks jump 02:00→03:00). Pinned in
    // TimeTests.swift: Foundation resolves the gap forward to 07:30Z, which
    // agrees byte-for-byte with the TS offset-subtraction result.
    #expect(slots[0].expectedTime == d("2026-03-08T07:30:00Z"))
}

@Test func dstFixedTime_0800_fallBack_singleSlot() {
    let result = computeScheduleSlots(
        medications: ["med-1"],
        schedulesByMedId: ["med-1": [fixedTimeSchedule("08:00")]],
        todaysDoses: [], lastTakenByMed: [:],
        dayStart: fallBackDayStart, dayEnd: fallBackDayEnd, timeZone: nyc,
        now: fallBackDayStart
    )
    let slots = flattenSorted(result)
    #expect(slots.count == 1)
    // 08:00 local on 11-01 is already past the 02:00→01:00 rollback, so it's EST (offset -5).
    #expect(slots[0].expectedTime == d("2026-11-01T13:00:00Z"))
}

@Test func dstFixedTime_0230_fallBack_afterAmbiguousWindow_singleSlot() {
    let result = computeScheduleSlots(
        medications: ["med-1"],
        schedulesByMedId: ["med-1": [fixedTimeSchedule("02:30")]],
        todaysDoses: [], lastTakenByMed: [:],
        dayStart: fallBackDayStart, dayEnd: fallBackDayEnd, timeZone: nyc,
        now: fallBackDayStart
    )
    let slots = flattenSorted(result)
    #expect(slots.count == 1)
    // 02:30 on 11-01 occurs only once (the ambiguous repeat is 01:00-01:59
    // only, per the pinned `wallClock_fallBackAmbiguousHour` case in
    // TimeTests.swift); it lands after the rollback, in EST (offset -5).
    #expect(slots[0].expectedTime == d("2026-11-01T07:30:00Z"))
}

@Test func dstWeeklyDaysOfWeek_springForwardSunday_includedVsExcluded() {
    let included = computeScheduleSlots(
        medications: ["med-1"],
        schedulesByMedId: ["med-1": [fixedTimeSchedule("08:00", daysOfWeek: [0])]],
        todaysDoses: [], lastTakenByMed: [:],
        dayStart: springForwardDayStart, dayEnd: springForwardDayEnd, timeZone: nyc,
        now: springForwardDayStart
    )
    #expect(flattenSorted(included).count == 1)

    let excluded = computeScheduleSlots(
        medications: ["med-1"],
        schedulesByMedId: ["med-1": [fixedTimeSchedule("08:00", daysOfWeek: [1, 2, 3, 4, 5, 6])]],
        todaysDoses: [], lastTakenByMed: [:],
        dayStart: springForwardDayStart, dayEnd: springForwardDayEnd, timeZone: nyc,
        now: springForwardDayStart
    )
    #expect(flattenSorted(excluded).isEmpty)
}

@Test func dstWeeklyDaysOfWeek_fallBackSunday_includedVsExcluded() {
    let included = computeScheduleSlots(
        medications: ["med-1"],
        schedulesByMedId: ["med-1": [fixedTimeSchedule("08:00", daysOfWeek: [0])]],
        todaysDoses: [], lastTakenByMed: [:],
        dayStart: fallBackDayStart, dayEnd: fallBackDayEnd, timeZone: nyc,
        now: fallBackDayStart
    )
    #expect(flattenSorted(included).count == 1)

    let excluded = computeScheduleSlots(
        medications: ["med-1"],
        schedulesByMedId: ["med-1": [fixedTimeSchedule("08:00", daysOfWeek: [1, 2, 3, 4, 5, 6])]],
        todaysDoses: [], lastTakenByMed: [:],
        dayStart: fallBackDayStart, dayEnd: fallBackDayEnd, timeZone: nyc,
        now: fallBackDayStart
    )
    #expect(flattenSorted(excluded).isEmpty)
}
