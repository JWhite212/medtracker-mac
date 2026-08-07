import Foundation
import GRDB

/// A flat `dose_log ⨝ medication` history row — no join record exists on the
/// records layer, so History materializes exactly the columns the timeline
/// needs. `local_day` is `localDate(taken_at, :tz)` for profile-tz grouping.
public struct HistoryRow: Decodable, FetchableRecord, Sendable, Equatable {
    public var doseId: String
    public var medicationId: String
    public var medicationName: String
    public var dosageAmount: String
    public var dosageUnit: String
    public var colour: String
    public var colourSecondary: String?
    public var pattern: String
    public var quantity: Int
    public var takenAt: Double
    public var status: String
    public var notes: String?
    public var sideEffects: String?
    public var localDay: String

    enum CodingKeys: String, CodingKey {
        case doseId = "dose_id"
        case medicationId = "medication_id"
        case medicationName = "medication_name"
        case dosageAmount = "dosage_amount"
        case dosageUnit = "dosage_unit"
        case colour
        case colourSecondary = "colour_secondary"
        case pattern
        case quantity
        case takenAt = "taken_at"
        case status
        case notes
        case sideEffects = "side_effects"
        case localDay = "local_day"
    }
}

/// The History filter set. Every field is optional; `nil` disables that
/// predicate via a `(:x IS NULL OR …)` bind, so one prepared statement serves
/// all combinations. Date bounds are sargable UTC epochs (never `localDate()`
/// on the column).
public struct HistoryFilter: Sendable, Equatable, Hashable {
    public var medicationId: String?
    public var status: String?
    public var fromEpoch: Double?
    public var toEpoch: Double?
    public var notesQuery: String?
    public var sideEffectName: String?
    public var sideEffectSeverity: String?

    public init(medicationId: String? = nil, status: String? = nil,
                fromEpoch: Double? = nil, toEpoch: Double? = nil,
                notesQuery: String? = nil, sideEffectName: String? = nil,
                sideEffectSeverity: String? = nil)
    {
        self.medicationId = medicationId
        self.status = status
        self.fromEpoch = fromEpoch
        self.toEpoch = toEpoch
        self.notesQuery = notesQuery
        self.sideEffectName = sideEffectName
        self.sideEffectSeverity = sideEffectSeverity
    }
}

public enum DoseLogQueries {
    /// One prepared statement: `dose_log ⨝ medication` (never filtering
    /// `is_archived` — a dose on an archived med still shows), each filter an
    /// optional bind, `ORDER BY d.taken_at DESC` (index-covered), `local_day`
    /// via `localDate`, and a growing `LIMIT`. Side-effect predicates use
    /// json1 `json_each`/`json_extract`.
    ///
    /// CONFIRM (§8-#13): query assumes **json1** is present in the deployment SQLite —
    /// system SQLite on macOS 15 ships it; if a build lacks it, degrade the side-effect
    /// predicates to `d.side_effects LIKE '%'||:x||'%'`.
    public static func page(_ db: Database, userId: String, tz: String,
                            filter: HistoryFilter, limit: Int) throws -> [HistoryRow]
    {
        try HistoryRow.fetchAll(db, sql: """
        SELECT d.id AS dose_id, d.medication_id AS medication_id,
               m.name AS medication_name, m.dosage_amount AS dosage_amount,
               m.dosage_unit AS dosage_unit, m.colour AS colour,
               m.colour_secondary AS colour_secondary, m.pattern AS pattern,
               d.quantity AS quantity, d.taken_at AS taken_at, d.status AS status,
               d.notes AS notes, d.side_effects AS side_effects,
               localDate(d.taken_at, :tz) AS local_day
        FROM dose_log d
        JOIN medication m ON m.id = d.medication_id
        WHERE d.user_id = :userId
          AND (:medicationId IS NULL OR d.medication_id = :medicationId)
          AND (:status IS NULL OR d.status = :status)
          AND (:fromEpoch IS NULL OR d.taken_at >= :fromEpoch)
          AND (:toEpoch IS NULL OR d.taken_at < :toEpoch)
          AND (:notesQuery IS NULL OR d.notes LIKE '%' || :notesQuery || '%')
          AND (:sideEffectName IS NULL OR EXISTS (
                 SELECT 1 FROM json_each(d.side_effects)
                 WHERE json_extract(json_each.value, '$.name') = :sideEffectName))
          AND (:sideEffectSeverity IS NULL OR EXISTS (
                 SELECT 1 FROM json_each(d.side_effects)
                 WHERE json_extract(json_each.value, '$.severity') = :sideEffectSeverity))
        ORDER BY d.taken_at DESC
        LIMIT :limit
        """, arguments: ["tz": tz, "userId": userId,
                         "medicationId": filter.medicationId,
                         "status": filter.status,
                         "fromEpoch": filter.fromEpoch,
                         "toEpoch": filter.toEpoch,
                         "notesQuery": filter.notesQuery,
                         "sideEffectName": filter.sideEffectName,
                         "sideEffectSeverity": filter.sideEffectSeverity,
                         "limit": limit])
    }
}
