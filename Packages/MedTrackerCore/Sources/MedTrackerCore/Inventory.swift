import Foundation

// Ports `src/lib/server/inventory.ts` (`dailyRateFor`, `classifyRefillSeverity`,
// `daysUntilRefill`), `expectedPerDayForSchedules` from
// `src/lib/server/analytics.ts:17-30`, and the legacy list-view
// `calculateDaysUntilRefill` from `src/lib/utils/time.ts:80-100` — the last
// one deferred here from Task 3 (Time.swift) per that task's report, since
// this task's "port from" scope explicitly includes it.
//
// Two distinct 30-day daily-rate signals exist in the web app, and this file
// keeps them faithfully separate rather than collapsing them into one:
//   - `dailyRateFor`'s third tier (`thirtyDayTakenQuantity / 30`) is the SUM
//     of `quantity` across `taken`-status dose logs in the last 30 days —
//     the signal `getRefillForecast` computes for the dashboard/refills card.
//   - `calculateDaysUntilRefill`'s `avgDailyConsumption` parameter is an
//     already-computed average the caller hands in (the legacy
//     medications-list view upstream counts ROWS of any status over 30
//     days, not summed taken-quantity). This function never computes that
//     average itself — it only consumes whatever's passed in, exactly as
//     the TS does — it just centralizes the schedule-precedence + floor
//     logic both callers share.

// MARK: - Expected doses/day per schedule row

/// Sum expected doses per day across a medication's schedule rows. Ports
/// `expectedPerDayForSchedules` (`analytics.ts:17-30`).
/// - `interval` rows contribute `24 / intervalHours`, only when the interval
///   is present and `> 0`.
/// - `fixed_time` rows contribute `1`, scaled to `daysOfWeek.count / 7` when
///   `daysOfWeek` is present and non-empty; only when `timeOfDay` is present.
/// - `prn` rows contribute `0`.
public func expectedPerDay(forSchedules rows: [ScheduleRow]) -> Double {
    var perDay = 0.0
    for row in rows {
        switch row.kind {
        case .prn:
            continue
        case .interval:
            guard let intervalHours = row.intervalHours else { continue }
            let hrs = NSDecimalNumber(decimal: intervalHours).doubleValue
            if hrs > 0 { perDay += 24 / hrs }
        case .fixedTime:
            guard let timeOfDay = row.timeOfDay, !timeOfDay.isEmpty else { continue }
            if let daysOfWeek = row.daysOfWeek, !daysOfWeek.isEmpty {
                perDay += Double(daysOfWeek.count) / 7
            } else {
                perDay += 1
            }
        }
    }
    return perDay
}

// MARK: - Daily-rate selection (3-tier)

/// Selects the daily consumption rate to drive a medication's refill
/// forecast. Ports `dailyRateFor` (`inventory.ts:32-51`). Tier order:
/// 1. Schedule rows, if `expectedPerDay(forSchedules:)` over them is `> 0`.
/// 2. The legacy `scheduleType`/`scheduleIntervalHours` columns, when
///    `legacyScheduleType == "scheduled"` and the interval is present and
///    `> 0` (`24 / intervalHours`) — a safety net for partially-migrated
///    medications where schedule rows exist but contribute nothing (e.g.
///    all-PRN).
/// 3. `thirtyDayTakenQuantity / 30`.
/// Returns `0` when no signal is available at all.
public func dailyRateFor(
    scheduleRows: [ScheduleRow],
    legacyScheduleType: String?,
    legacyIntervalHours: Decimal?,
    thirtyDayTakenQuantity: Int
) -> Double {
    if !scheduleRows.isEmpty {
        let scheduledRate = expectedPerDay(forSchedules: scheduleRows)
        if scheduledRate > 0 { return scheduledRate }
    }

    if legacyScheduleType == "scheduled", let legacyIntervalHours {
        let hrs = NSDecimalNumber(decimal: legacyIntervalHours).doubleValue
        if hrs > 0 { return 24 / hrs }
    }

    return Double(thirtyDayTakenQuantity) / 30
}

// MARK: - Refill severity classification

/// Classifies a refill forecast by urgency. Ports `classifyRefillSeverity`
/// (`inventory.ts:19-25`). `nil` → `.ok`; `≤ 3` → `.critical`; `≤ 7` →
/// `.warning`; `≤ 14` → `.watch`; else `.ok`.
public func classifyRefillSeverity(days: Int?) -> RefillSeverity {
    guard let days else { return .ok }
    if days <= 3 { return .critical }
    if days <= 7 { return .warning }
    if days <= 14 { return .watch }
    return .ok
}

// MARK: - Days until refill

/// Days of remaining stock at the given daily rate. Ports `daysUntilRefill`
/// (`inventory.ts:53-57`). `nil` when `inventoryCount` is `nil` or
/// `dailyRate ≤ 0`; otherwise `floor(inventoryCount / dailyRate)`.
public func daysUntilRefill(inventoryCount: Int?, dailyRate: Double) -> Int? {
    guard let inventoryCount else { return nil }
    guard dailyRate > 0 else { return nil }
    return Int(floor(Double(inventoryCount) / dailyRate))
}

// MARK: - Legacy list-view days-until-refill

/// The legacy medications-list-view days-until-refill calculation. Ports
/// `calculateDaysUntilRefill` (`src/lib/utils/time.ts:80-100`).
///
/// `scheduleType == "scheduled"` with a positive `scheduleIntervalHours`
/// takes precedence over `avgDailyConsumption` — a schedule is trusted over
/// dose history even for a freshly-added medication with no logged doses
/// yet. Otherwise falls back to `avgDailyConsumption` (the caller's own
/// 30-day average — see the file-level note on how this differs from
/// `dailyRateFor`'s signal). `nil` when `inventoryCount` is `nil` or the
/// selected daily rate is `≤ 0`.
public func calculateDaysUntilRefill(
    inventoryCount: Int?,
    avgDailyConsumption: Double,
    scheduleType: String? = nil,
    scheduleIntervalHours: Decimal? = nil
) -> Int? {
    guard let inventoryCount else { return nil }

    var scheduledDaily = 0.0
    if scheduleType == "scheduled", let scheduleIntervalHours {
        let hrs = NSDecimalNumber(decimal: scheduleIntervalHours).doubleValue
        if hrs > 0 { scheduledDaily = 24 / hrs }
    }

    let dailyRate = scheduledDaily > 0 ? scheduledDaily : avgDailyConsumption
    guard dailyRate > 0 else { return nil }
    return Int(floor(Double(inventoryCount) / dailyRate))
}
