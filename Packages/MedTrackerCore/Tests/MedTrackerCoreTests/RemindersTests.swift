import Foundation
import Testing
@testable import MedTrackerCore

// Ports the PURE cases of `tests/unit/reminders-dedupe.test.ts` — the
// `isScheduleOverdue`/`computeOverdueSlot` interval + fixed_time branches and
// the `buildOverdueDedupeKey`/`buildLowInventoryDedupeKey` builders. The TS
// suite exercises a single `computeOverdueSlot(row, now)` that branches
// internally on `row.scheduleKind`; this port splits that into
// `intervalOverdueSlot` and `fixedTimeOverdueSlot` per the Task 10 interface,
// so each TS case is transcribed onto whichever of the two now owns it.
// `isScheduleOverdue(row, now)` (the TS boolean wrapper) has no direct Swift
// counterpart — its cases are transcribed as `!= nil` / `== nil` assertions
// on the corresponding slot function, which is equivalent (TS:
// `isScheduleOverdue = computeOverdueSlot(...) !== null`).

private let isoFormatter = ISO8601DateFormatter()
private let isoFormatterWithFractionalSeconds: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

/// Parses an ISO-8601 instant, accepting both plain-seconds and
/// fractional-seconds (`Date#toISOString()`-shaped) forms.
private func d(_ s: String) -> Date {
    isoFormatter.date(from: s) ?? isoFormatterWithFractionalSeconds.date(from: s)!
}

private let utc = TimeZone(identifier: "UTC")!

/// `const now = new Date("2026-05-01T15:00:00.000Z");` (reminders-dedupe.test.ts:10)
private let now = d("2026-05-01T15:00:00.000Z")

// MARK: - overdueDedupeKey (verbatim from `describe("buildOverdueDedupeKey")`)

@Test func overdueDedupeKey_isDeterministicForTheSameInputs() {
    let slot = d("2026-05-01T08:00:00.000Z")
    #expect(
        overdueDedupeKey(userId: "u", medicationId: "m", scheduleKind: .fixedTime, scheduleId: "s", slot: slot)
            == overdueDedupeKey(userId: "u", medicationId: "m", scheduleKind: .fixedTime, scheduleId: "s", slot: slot)
    )
}

@Test func overdueDedupeKey_differsWhenSlotDiffers() {
    let a = overdueDedupeKey(
        userId: "u", medicationId: "m", scheduleKind: .fixedTime, scheduleId: "s",
        slot: d("2026-05-01T08:00:00Z")
    )
    let b = overdueDedupeKey(
        userId: "u", medicationId: "m", scheduleKind: .fixedTime, scheduleId: "s",
        slot: d("2026-05-01T20:00:00Z")
    )
    #expect(a != b)
}

@Test func overdueDedupeKey_differsWhenScheduleIdDiffers() {
    let slot = d("2026-05-01T08:00:00Z")
    #expect(
        overdueDedupeKey(userId: "u", medicationId: "m", scheduleKind: .fixedTime, scheduleId: "s1", slot: slot)
            != overdueDedupeKey(userId: "u", medicationId: "m", scheduleKind: .fixedTime, scheduleId: "s2", slot: slot)
    )
}

@Test func overdueDedupeKey_encodesTheSlotAsISO8601() {
    let slot = d("2026-05-01T08:00:00.000Z")
    let key = overdueDedupeKey(userId: "u", medicationId: "m", scheduleKind: .fixedTime, scheduleId: "s", slot: slot)
    #expect(key.contains("2026-05-01T08:00:00.000Z"))
}

/// Not in the TS suite, but pins the exact raw strings the key embeds per
/// schedule kind (Task 10 brief: `scheduleKindRaw` is the web's string).
@Test func overdueDedupeKey_embedsTheWebScheduleKindRawString() {
    let slot = d("2026-05-01T08:00:00.000Z")
    #expect(
        overdueDedupeKey(userId: "u", medicationId: "m", scheduleKind: .interval, scheduleId: "s", slot: slot)
            == "u:m:overdue:interval:s:2026-05-01T08:00:00.000Z"
    )
    #expect(
        overdueDedupeKey(userId: "u", medicationId: "m", scheduleKind: .fixedTime, scheduleId: "s", slot: slot)
            == "u:m:overdue:fixed_time:s:2026-05-01T08:00:00.000Z"
    )
    #expect(
        overdueDedupeKey(userId: "u", medicationId: "m", scheduleKind: .prn, scheduleId: "s", slot: slot)
            == "u:m:overdue:prn:s:2026-05-01T08:00:00.000Z"
    )
}

// MARK: - lowInventoryDedupeKey (verbatim from `describe("buildLowInventoryDedupeKey")`)

@Test func lowInventoryDedupeKey_changesOnlyWhenTheCountChanges() {
    #expect(lowInventoryDedupeKey(userId: "u", medicationId: "m", count: 5)
        == lowInventoryDedupeKey(userId: "u", medicationId: "m", count: 5))
    #expect(lowInventoryDedupeKey(userId: "u", medicationId: "m", count: 5)
        != lowInventoryDedupeKey(userId: "u", medicationId: "m", count: 4))
}

@Test func lowInventoryDedupeKey_includesTheLowInventoryMarker() {
    #expect(lowInventoryDedupeKey(userId: "u", medicationId: "m", count: 5).contains(":low_inventory:"))
}

// MARK: - intervalOverdueSlot (verbatim from `describe("isScheduleOverdue — interval schedules")`)

@Test func intervalOverdueSlot_neverTakenIsNotOverdue() {
    #expect(intervalOverdueSlot(intervalHours: 6, lastTakenAt: nil, now: now) == nil)
}

@Test func intervalOverdueSlot_takenInsideTheWindowIsNotOverdue() {
    let oneHourAgo = now.addingTimeInterval(-3_600)
    #expect(intervalOverdueSlot(intervalHours: 6, lastTakenAt: oneHourAgo, now: now) == nil)
}

@Test func intervalOverdueSlot_takenLongerAgoThanTheWindowIsOverdue() {
    let eightHoursAgo = now.addingTimeInterval(-8 * 3_600)
    #expect(intervalOverdueSlot(intervalHours: 6, lastTakenAt: eightHoursAgo, now: now) != nil)
}

@Test func intervalOverdueSlot_atExactlyTheWindowBoundaryIsNotOverdue() {
    // Strict greater-than: exactly 6h ago is NOT overdue for a 6h interval.
    let sixHoursAgo = now.addingTimeInterval(-6 * 3_600)
    #expect(intervalOverdueSlot(intervalHours: 6, lastTakenAt: sixHoursAgo, now: now) == nil)
}

// MARK: - fixedTimeOverdueSlot (verbatim from `describe("isScheduleOverdue — fixed-time schedules (UTC)")`)

@Test func fixedTimeOverdueSlot_futureSlotTodayIsNotOverdue() {
    #expect(
        fixedTimeOverdueSlot(timeOfDay: "23:00", daysOfWeek: nil, now: now, timeZone: utc, hasTakenWithin1h: false)
            == nil
    )
}

@Test func fixedTimeOverdueSlot_pastSlotTodayWithNoDoseIsOverdue() {
    #expect(
        fixedTimeOverdueSlot(timeOfDay: "08:00", daysOfWeek: nil, now: now, timeZone: utc, hasTakenWithin1h: false)
            != nil
    )
}

@Test func fixedTimeOverdueSlot_pastSlotWithADoseInsideToleranceIsNotOverdue() {
    // slotEightAm = new Date("2026-05-01T08:00:00.000Z") taken exactly at the slot.
    #expect(
        fixedTimeOverdueSlot(timeOfDay: "08:00", daysOfWeek: nil, now: now, timeZone: utc, hasTakenWithin1h: true)
            == nil
    )
}

@Test func fixedTimeOverdueSlot_pastSlotWithADoseOutsideToleranceIsOverdue() {
    // Tolerance is 60 minutes; a dose taken the day before shouldn't suppress the slot
    // — the caller resolves this to `hasTakenWithin1h: false`.
    #expect(
        fixedTimeOverdueSlot(timeOfDay: "08:00", daysOfWeek: nil, now: now, timeZone: utc, hasTakenWithin1h: false)
            != nil
    )
}

@Test func fixedTimeOverdueSlot_dayOfWeekExcludesTodayIsNotOverdue() {
    // 2026-05-01 is a Friday (day 5). Restrict to Mon (1) only.
    #expect(
        fixedTimeOverdueSlot(timeOfDay: "08:00", daysOfWeek: [1], now: now, timeZone: utc, hasTakenWithin1h: false)
            == nil
    )
}

@Test func fixedTimeOverdueSlot_dayOfWeekIncludesTodayStillOverdueWhenSlotInPast() {
    // 2026-05-01 is a Friday (day 5).
    #expect(
        fixedTimeOverdueSlot(timeOfDay: "08:00", daysOfWeek: [5], now: now, timeZone: utc, hasTakenWithin1h: false)
            != nil
    )
}

// MARK: - Slot instants (verbatim from `describe("computeOverdueSlot — returns the actual slot Date used in dedupe keys")`)

@Test func intervalOverdueSlot_isLastTakenAtPlusIntervalHours() {
    let lastTaken = d("2026-05-01T03:00:00.000Z")
    let slot = intervalOverdueSlot(intervalHours: 6, lastTakenAt: lastTaken, now: now)
    #expect(slot != nil)
    #expect(isoFormatterWithFractionalSeconds.string(from: slot!) == "2026-05-01T09:00:00.000Z")
}

@Test func fixedTimeOverdueSlot_isTheSlotUTCForToday() {
    let slot = fixedTimeOverdueSlot(timeOfDay: "08:00", daysOfWeek: nil, now: now, timeZone: utc, hasTakenWithin1h: false)
    #expect(slot != nil)
    #expect(isoFormatterWithFractionalSeconds.string(from: slot!) == "2026-05-01T08:00:00.000Z")
}

@Test func fixedTimeOverdueSlot_returnsNilWhenNotOverdue() {
    #expect(
        fixedTimeOverdueSlot(timeOfDay: "23:00", daysOfWeek: nil, now: now, timeZone: utc, hasTakenWithin1h: false)
            == nil
    )
}

@Test func intervalAndFixedTimeProduceDifferentDedupeKeysForTheSameMed() {
    let lastTaken = d("2026-05-01T03:00:00.000Z")
    let intervalSlot = intervalOverdueSlot(intervalHours: 6, lastTakenAt: lastTaken, now: now)!
    let fixedSlot = fixedTimeOverdueSlot(
        timeOfDay: "08:00", daysOfWeek: nil, now: now, timeZone: utc, hasTakenWithin1h: false
    )!
    let intervalKey = overdueDedupeKey(userId: "u", medicationId: "m", scheduleKind: .interval, scheduleId: "s1", slot: intervalSlot)
    let fixedKey = overdueDedupeKey(userId: "u", medicationId: "m", scheduleKind: .fixedTime, scheduleId: "s2", slot: fixedSlot)
    #expect(intervalKey != fixedKey)
}
