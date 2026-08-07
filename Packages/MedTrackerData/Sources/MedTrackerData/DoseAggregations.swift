import Foundation
import GRDB

/// One `(medication, local calendar day)` bucket of taken quantity — the
/// 14-day sparkline series (§5.2.1) and any per-day taken-quantity rollup.
/// `local_day` is `localDate(taken_at, :tz)` so bucketing honours the synced
/// profile timezone entirely in SQL (see `LocalDateFunction.swift`).
public struct DailyDoseCount: Decodable, FetchableRecord, Sendable, Equatable {
    public var medicationId: String
    public var localDay: String
    public var totalQuantity: Int

    enum CodingKeys: String, CodingKey {
        case medicationId = "medication_id"
        case localDay = "local_day"
        case totalQuantity = "total_quantity"
    }
}

/// Per-medication rollup feeding the refill forecast + adherence mini-bar
/// (§5.1.2 / §5.2.1): 7-day taken count, 30-day taken quantity, and the
/// last-taken instant (interval anchor for the timing badge).
public struct PerMedStat: Decodable, FetchableRecord, Sendable, Equatable {
    public var medicationId: String
    public var taken7Count: Int
    public var lastTakenAt: Double?
    public var thirtyDayQuantity: Int

    enum CodingKeys: String, CodingKey {
        case medicationId = "medication_id"
        case taken7Count = "taken7_count"
        case lastTakenAt = "last_taken_at"
        case thirtyDayQuantity = "thirty_day_quantity"
    }
}

public enum DoseAggregations {
    private static let day: Double = 86_400

    /// 14-day (caller-bounded) taken-quantity per `(medication, local day)`.
    /// Date bounds are a sargable half-open UTC-epoch interval on `taken_at`
    /// (never `localDate()` on the column), so the composite indexes apply.
    public static func dailyTakenQuantity(_ db: Database, userId: String, tz: String,
                                          fromEpoch: Double, toEpoch: Double) throws -> [DailyDoseCount]
    {
        try DailyDoseCount.fetchAll(db, sql: """
        SELECT medication_id,
               localDate(taken_at, :tz) AS local_day,
               SUM(quantity) AS total_quantity
        FROM dose_log
        WHERE user_id = :userId AND status = 'taken'
          AND taken_at >= :fromEpoch AND taken_at < :toEpoch
        GROUP BY medication_id, local_day
        ORDER BY local_day
        """, arguments: ["tz": tz, "userId": userId,
                         "fromEpoch": fromEpoch, "toEpoch": toEpoch])
    }

    /// 7-day taken count + 30-day taken quantity (windowed via conditional
    /// aggregation) + unbounded `MAX(taken_at)` per med, in one scan.
    public static func perMedStats(_ db: Database, userId: String, now: Double) throws -> [PerMedStat] {
        try PerMedStat.fetchAll(db, sql: """
        SELECT medication_id,
               COUNT(CASE WHEN taken_at >= :sevenDayStart THEN 1 END) AS taken7_count,
               MAX(taken_at) AS last_taken_at,
               COALESCE(SUM(CASE WHEN taken_at >= :thirtyDayStart THEN quantity ELSE 0 END), 0)
                 AS thirty_day_quantity
        FROM dose_log
        WHERE user_id = :userId AND status = 'taken'
        GROUP BY medication_id
        """, arguments: ["userId": userId,
                         "sevenDayStart": now - 7 * day,
                         "thirtyDayStart": now - 30 * day])
    }

    /// Distinct local calendar days (profile tz) on which ANY dose was taken,
    /// newest first — the unbounded streak input for `calculateStreak` (§5.1.1).
    public static func distinctTakenLocalDatesNewestFirst(_ db: Database, userId: String,
                                                          tz: String) throws -> [String]
    {
        try String.fetchAll(db, sql: """
        SELECT DISTINCT localDate(taken_at, :tz) AS local_day
        FROM dose_log
        WHERE user_id = :userId AND status = 'taken'
        ORDER BY local_day DESC
        """, arguments: ["tz": tz, "userId": userId])
    }
}
