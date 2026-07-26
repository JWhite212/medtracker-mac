import Foundation

// Ports the PURE parts of `src/lib/server/reminders/domain.ts` only — the
// overdue-slot tests (`computeOverdueSlot`'s `interval` and `fixed_time`
// branches) and the dedupe-key builders (`buildOverdueDedupeKey`,
// `buildLowInventoryDedupeKey`). The dispatch/claim/DB/channel code in that
// file (everything outside `domain.ts`) is explicitly NOT ported here — this
// package has no persistence or notification-delivery concerns (Phase 1a is
// domain-core only; dispatch lands in Phase 2).
//
// The TS `computeOverdueSlot` takes a single `OverdueRow` with a
// `scheduleKind` discriminant and internally branches on it. This port splits
// that branch into two standalone functions — `intervalOverdueSlot` and
// `fixedTimeOverdueSlot` — per the Task 10 interface; the caller (Phase 1b's
// dispatch layer) picks which one to call based on the schedule's own
// `ScheduleKind`, which is exactly what the TS branch does internally.

// MARK: - Interval overdue slot

/// The overdue slot instant for an `interval` schedule, or `nil` if not
/// overdue. Ports the `scheduleKind === "interval"` branch of
/// `computeOverdueSlot` (`domain.ts:17-23`).
///
/// - `lastTakenAt == nil` (never taken) → `nil` — there is no baseline to
///   measure "overdue" from yet.
/// - Overdue iff `now - lastTakenAt` **strictly exceeds** `intervalHours`
///   (`domain.ts:21`: `if (now - last <= intervalMs) return null`) — exactly
///   at the boundary is NOT overdue.
/// - The returned slot is `lastTakenAt + intervalHours` (`domain.ts:22`), not
///   `now` — this is the instant embedded in the dedupe key, so it stays
///   stable across repeated calls until the next dose is logged.
public func intervalOverdueSlot(
    intervalHours: Decimal,
    lastTakenAt: Date?,
    now: Date
) -> Date? {
    guard let lastTakenAt else { return nil }
    let intervalSeconds = NSDecimalNumber(decimal: intervalHours).doubleValue * 3600
    guard now.timeIntervalSince(lastTakenAt) > intervalSeconds else { return nil }
    return lastTakenAt.addingTimeInterval(intervalSeconds)
}

// MARK: - Fixed-time overdue slot

/// The overdue slot instant for a `fixed_time` schedule, or `nil` if not
/// overdue. Ports the `scheduleKind === "fixed_time"` branch of
/// `computeOverdueSlot` (`domain.ts:25-44`).
///
/// Resolution order (matches the TS exactly):
/// 1. Resolve today's local date in `timeZone` (from `now`) and combine it
///    with `timeOfDay` via `wallClockToUTC` — the DST-aware equivalent of the
///    TS's `getLocalDateString` + `localTimeOnDateToUtc` pair.
/// 2. If that slot instant is still in the future relative to `now` → `nil`
///    (`domain.ts:31`).
/// 3. If `daysOfWeek` is non-empty, the slot's **local** day of week (via
///    `localDayOfWeek`, `0 = Sunday … 6 = Saturday`) must be a member, else
///    `nil` (`domain.ts:33-36`).
/// 4. If `hasTakenWithin1h` (the caller has already checked
///    `abs(lastTakenAt - slot) <= FIXED_TIME_TOLERANCE_MS`, `domain.ts:38-41`)
///    → `nil`, suppressing the reminder.
///
/// Otherwise returns the resolved slot instant.
public func fixedTimeOverdueSlot(
    timeOfDay: String,
    daysOfWeek: [Int]?,
    now: Date,
    timeZone: TimeZone,
    hasTakenWithin1h: Bool
) -> Date? {
    let segments = timeOfDay.split(separator: ":")
    guard segments.count == 2, let hour = Int(segments[0]), let minute = Int(segments[1]) else {
        return nil
    }

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let today = calendar.dateComponents([.year, .month, .day], from: now)
    guard let year = today.year, let month = today.month, let day = today.day else { return nil }

    let slot = wallClockToUTC(year: year, month: month, day: day, hour: hour, minute: minute, timeZone: timeZone)

    if slot > now { return nil }

    if let daysOfWeek, !daysOfWeek.isEmpty {
        let dow = localDayOfWeek(slot, timeZone: timeZone)
        if !daysOfWeek.contains(dow) { return nil }
    }

    if hasTakenWithin1h { return nil }

    return slot
}

// MARK: - ISO-8601-with-milliseconds formatting (JS `Date.toISOString()` parity)

/// Formats a `Date` exactly like JS `Date.toISOString()` —
/// `yyyy-MM-ddTHH:mm:ss.SSSZ`, always UTC, always 3 fractional-second digits,
/// always a literal `Z`. Used to embed the slot instant in dedupe-key
/// strings so the Mac app's `UNNotificationRequest` identifiers (Phase 2)
/// match the web app's byte-for-byte.
private let isoWithMilliseconds: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

private func jsISOString(_ date: Date) -> String {
    isoWithMilliseconds.string(from: date)
}

// MARK: - Dedupe-key builders

/// Builds the dedupe-key identifier for an overdue reminder. Ports
/// `buildOverdueDedupeKey` (`domain.ts:53-61`) verbatim:
/// `"{userId}:{medicationId}:overdue:{scheduleKind}:{scheduleId}:{slotISO}"`,
/// where `scheduleKind` is the web's raw string (`ScheduleKind.rawValue` —
/// `"interval"` / `"fixed_time"` / `"prn"`) and `slotISO` is
/// `slot.toISOString()`-equivalent (milliseconds + `Z`).
public func overdueDedupeKey(
    userId: String,
    medicationId: String,
    scheduleKind: ScheduleKind,
    scheduleId: String,
    slot: Date
) -> String {
    "\(userId):\(medicationId):overdue:\(scheduleKind.rawValue):\(scheduleId):\(jsISOString(slot))"
}

/// Builds the dedupe-key identifier for a low-inventory reminder. Ports
/// `buildLowInventoryDedupeKey` (`domain.ts:63-69`) verbatim:
/// `"{userId}:{medicationId}:low_inventory:{count}"`.
public func lowInventoryDedupeKey(
    userId: String,
    medicationId: String,
    count: Int
) -> String {
    "\(userId):\(medicationId):low_inventory:\(count)"
}
