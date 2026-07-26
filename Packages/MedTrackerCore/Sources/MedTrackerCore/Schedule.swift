import Foundation

// Ports `src/lib/utils/schedule.ts`. Reuses the DST-critical primitives from
// Task 3 (`wallClockToUTC`, `localDayOfWeek`, `localDateString`, `jsRound`) —
// no offset-subtraction date math is reimplemented here.

/// ±1 hour, in seconds. Ports the TS `MATCH_TOLERANCE_MS = 60 * 60 * 1000`
/// (`schedule.ts:28`) — the greedy dose↔slot matching window.
private let matchToleranceSeconds: TimeInterval = 3600

// MARK: - Local-hour helper (component extraction only — not DST-critical)

/// A proleptic-Gregorian calendar pinned to `timeZone`, used only to read
/// the local hour component off an instant (`groupSlotsByTimeOfDay`). This is
/// plain component extraction, not wall-clock⇄UTC resolution, so it doesn't
/// duplicate the DST-sensitive logic in `Time.swift`.
private func gregorianCalendar(_ timeZone: TimeZone) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    return calendar
}

private func localHour(_ date: Date, timeZone: TimeZone) -> Int {
    gregorianCalendar(timeZone).component(.hour, from: date)
}

/// All local calendar dates (`yyyy-MM-dd`) touched by `[start, end)`, sampled
/// every 6 hours plus the instant just before `end`. Ports the TS
/// `getLocalDatesInRange` (`schedule.ts:58-68`) — a 6h step never skips a
/// local calendar day even on a 23h/25h DST-transition day.
private func localDatesInRange(from start: Date, to end: Date, timeZone: TimeZone) -> [String] {
    var dates = Set<String>()
    let stepSeconds: TimeInterval = 6 * 60 * 60
    var t = start.timeIntervalSinceReferenceDate
    let endTime = end.timeIntervalSinceReferenceDate
    while t < endTime {
        dates.insert(localDateString(Date(timeIntervalSinceReferenceDate: t), timeZone: timeZone))
        t += stepSeconds
    }
    if endTime > start.timeIntervalSinceReferenceDate {
        dates.insert(localDateString(Date(timeIntervalSinceReferenceDate: endTime - 0.001), timeZone: timeZone))
    }
    return dates.sorted()
}

// MARK: - Interval schedule expansion

/// Expected instants for an `interval` schedule row within `[dayStart,
/// dayEnd)`. Ports `expectedTimesForInterval` (`schedule.ts:120-152`):
/// project forward from `anchor` by `intervalHours`; if `anchor` is before
/// `dayStart`, fast-forward it by `ceil((dayStart − anchor) / interval)`
/// whole intervals first; include `anchor` itself if it falls inside the
/// window (even if the stepped series doesn't happen to land on it).
private func expectedTimesForInterval(
    intervalHours: Decimal,
    anchor: Date,
    dayStart: Date,
    dayEnd: Date
) -> [Date] {
    let hours = NSDecimalNumber(decimal: intervalHours).doubleValue
    guard hours > 0 else { return [] }
    let intervalSeconds = hours * 3600

    var t = anchor
    if t < dayStart {
        let diff = dayStart.timeIntervalSince(t)
        let intervals = (diff / intervalSeconds).rounded(.up)
        t = t.addingTimeInterval(intervals * intervalSeconds)
    }

    var out: [Date] = []
    while t < dayEnd {
        out.append(t)
        t = t.addingTimeInterval(intervalSeconds)
    }

    if anchor >= dayStart, anchor < dayEnd, !out.contains(anchor) {
        out.append(anchor)
    }

    out.sort()
    return out
}

// MARK: - Fixed-time schedule expansion

/// Expected instants for a `fixed_time` schedule row within `[dayStart,
/// dayEnd)`. Ports `expectedTimesForFixedTime` (`schedule.ts:154-176`): one
/// instant per local calendar date in the window (resolved via
/// `wallClockToUTC`), filtered to instants actually inside the window and to
/// `daysOfWeek` (0=Sun…6=Sat) when non-empty.
private func expectedTimesForFixedTime(
    schedule: ScheduleRow,
    dayStart: Date,
    dayEnd: Date,
    timeZone: TimeZone
) -> [Date] {
    guard let timeOfDay = schedule.timeOfDay else { return [] }
    let parts = timeOfDay.split(separator: ":")
    guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]) else { return [] }

    let allowed = schedule.daysOfWeek
    var out: [Date] = []

    for dateStr in localDatesInRange(from: dayStart, to: dayEnd, timeZone: timeZone) {
        let comps = dateStr.split(separator: "-")
        guard comps.count == 3,
              let year = Int(comps[0]), let month = Int(comps[1]), let day = Int(comps[2])
        else { continue }

        let utc = wallClockToUTC(year: year, month: month, day: day, hour: hour, minute: minute, timeZone: timeZone)
        if utc < dayStart || utc >= dayEnd { continue }

        if let allowed, !allowed.isEmpty, !allowed.contains(localDayOfWeek(utc, timeZone: timeZone)) {
            continue
        }

        out.append(utc)
    }

    return out
}

// MARK: - computeScheduleSlots

/// Computes expected dose schedule slots for `[dayStart, dayEnd)`, grouped by
/// medication id. Ports `computeScheduleSlots` (`schedule.ts:187-286`).
///
/// - `medications`: the medication ids to compute slots for (lean — the pure
///   computation never needs display fields like name/colour/pattern).
/// - `schedulesByMedId`: each medication's schedule rows; a medication with
///   no entry (or an empty array) produces no slots.
/// - `todaysDoses`: the dose log rows to match slots against.
/// - `lastTakenByMed`: the most recent taken dose per medication, used as the
///   anchor for `interval` rows (falls back to `dayStart` when absent).
///
/// Per medication: walk every non-PRN schedule row, union the expected
/// instants, dedupe by exact instant, then greedily match each slot
/// (ascending order) to the earliest still-unused dose within ±1 hour.
/// Status: a matched `skipped` dose → `.skipped`; a matched `missed` dose →
/// `.overdue` (it wasn't actually taken); any other matched dose → `.taken`;
/// an unmatched slot at or before `now` → `.overdue`; otherwise `.upcoming`.
/// PRN rows never emit slots.
public func computeScheduleSlots(
    medications: [String],
    schedulesByMedId: [String: [ScheduleRow]],
    todaysDoses: [DoseEvent],
    lastTakenByMed: [String: Date],
    dayStart: Date,
    dayEnd: Date,
    timeZone: TimeZone,
    now: Date
) -> [String: [ScheduleSlot]] {
    var dosesByMedId: [String: [DoseEvent]] = [:]
    for dose in todaysDoses {
        dosesByMedId[dose.medicationId, default: []].append(dose)
    }

    var result: [String: [ScheduleSlot]] = [:]

    for medId in medications {
        let medSchedules = schedulesByMedId[medId] ?? []
        if medSchedules.isEmpty { continue }

        var expectedTimes: [Date] = []

        for schedule in medSchedules {
            switch schedule.kind {
            case .prn:
                continue
            case .interval:
                guard let intervalHours = schedule.intervalHours, intervalHours > 0 else { continue }
                let anchor = lastTakenByMed[medId] ?? dayStart
                expectedTimes.append(contentsOf: expectedTimesForInterval(
                    intervalHours: intervalHours, anchor: anchor, dayStart: dayStart, dayEnd: dayEnd
                ))
            case .fixedTime:
                expectedTimes.append(contentsOf: expectedTimesForFixedTime(
                    schedule: schedule, dayStart: dayStart, dayEnd: dayEnd, timeZone: timeZone
                ))
            }
        }

        if expectedTimes.isEmpty { continue }

        // Dedupe by exact instant — two schedule rows might emit the same time.
        var seen = Set<TimeInterval>()
        var dedup: [Date] = []
        for t in expectedTimes {
            let key = t.timeIntervalSinceReferenceDate
            if seen.contains(key) { continue }
            seen.insert(key)
            dedup.append(t)
        }
        dedup.sort()

        let medDoses = dosesByMedId[medId] ?? []
        var usedDoseIds = Set<String>()
        var slots: [ScheduleSlot] = []

        for expected in dedup {
            let matchedDose = medDoses.first { dose in
                !usedDoseIds.contains(dose.id)
                    && abs(dose.takenAt.timeIntervalSince(expected)) <= matchToleranceSeconds
            }
            if let matchedDose { usedDoseIds.insert(matchedDose.id) }

            let status: SlotStatus
            if let matchedDose {
                switch matchedDose.status {
                case .skipped: status = .skipped
                // A "missed" dose row hasn't actually been consumed, so the
                // slot is still unfulfilled — render it as overdue, not taken.
                case .missed: status = .overdue
                case .taken: status = .taken
                }
            } else if expected <= now {
                status = .overdue
            } else {
                status = .upcoming
            }

            slots.append(ScheduleSlot(
                medicationId: medId,
                expectedTime: expected,
                status: status,
                matchedDoseId: matchedDose?.id
            ))
        }

        result[medId] = slots
    }

    return result
}

// MARK: - computeTimingStatus

/// Computes the timing status of a single interval-based medication against
/// `now`. Ports `computeTimingStatus` from `src/lib/utils/time.ts` (the cases
/// transcribed in `tests/unit/time.test.ts`'s `computeTimingStatus` block —
/// deferred to this task since it depends on nothing but `jsRound`).
///
/// Never taken → `(.overdue, -1)`. Otherwise `nextDue = lastEventAt +
/// intervalHours`; `ms = nextDue − now` in milliseconds: `ms ≤ −60_000` →
/// `.overdue`; `ms ≤ 60_000` → `.dueNow`; `ms ≤ 3_600_000` → `.dueSoon`; else
/// `.ok`. `minutesUntilDue = jsRound(ms / 60_000)`.
public func computeTimingStatus(
    intervalHours: Decimal,
    lastEventAt: Date?,
    now: Date
) -> (status: TimingStatus, minutesUntilDue: Int) {
    guard let lastEventAt else {
        return (.overdue, -1)
    }

    let hours = NSDecimalNumber(decimal: intervalHours).doubleValue
    let nextDue = lastEventAt.addingTimeInterval(hours * 3600)
    let ms = nextDue.timeIntervalSince(now) * 1000

    let status: TimingStatus
    if ms <= -60_000 {
        status = .overdue
    } else if ms <= 60_000 {
        status = .dueNow
    } else if ms <= 3_600_000 {
        status = .dueSoon
    } else {
        status = .ok
    }

    return (status, jsRound(ms / 60_000))
}

// MARK: - Time-of-day bucketing

/// Classifies a local hour (0-23) into a time-of-day bucket. Ports
/// `classifyHour` (`schedule.ts:33-38`).
public func classifyHour(_ localHour: Int) -> TimeOfDayBucket {
    if localHour >= 5, localHour < 12 { return .morning }
    if localHour >= 12, localHour < 17 { return .afternoon }
    if localHour >= 17, localHour < 21 { return .evening }
    return .night
}

/// Groups schedule slots into time-of-day sections by the local hour of each
/// slot's `expectedTime`, ascending within each bucket, omitting empty
/// buckets, ordered morning→night. Ports `groupSlotsByTimeOfDay`
/// (`schedule.ts:292-322`).
public func groupSlotsByTimeOfDay(
    _ slots: [ScheduleSlot],
    timeZone: TimeZone
) -> [(bucket: TimeOfDayBucket, slots: [ScheduleSlot])] {
    var buckets: [TimeOfDayBucket: [ScheduleSlot]] = [:]

    for slot in slots {
        let bucket = classifyHour(localHour(slot.expectedTime, timeZone: timeZone))
        buckets[bucket, default: []].append(slot)
    }

    for key in buckets.keys {
        buckets[key]?.sort { $0.expectedTime < $1.expectedTime }
    }

    return TimeOfDayBucket.allCases.compactMap { bucket in
        guard let bucketSlots = buckets[bucket], !bucketSlots.isEmpty else { return nil }
        return (bucket, bucketSlots)
    }
}
