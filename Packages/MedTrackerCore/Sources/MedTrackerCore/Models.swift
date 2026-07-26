import Foundation

// MARK: - Schedule domain

/// Mirrors the TS `MedicationSchedule.scheduleKind` discriminated union
/// (`"interval" | "fixed_time" | "prn"`, `src/lib/server/schedules.ts`).
/// The raw value is the exact web string — used verbatim in
/// `overdueDedupeKey` (`Reminders.swift`) so dedupe-key identifiers match the
/// web app's byte-for-byte.
public enum ScheduleKind: String, Equatable, Hashable, Sendable {
    case interval = "interval"
    case fixedTime = "fixed_time"
    case prn = "prn"
}

/// A single schedule row for a medication, as consumed by
/// `computeScheduleSlots`. Deliberately lean: no `id`/`medicationId`/
/// `sortOrder`/`effectiveFrom`/`effectiveTo` — grouping by medication is done
/// by the caller via `schedulesByMedId`, and the effective-date window is
/// resolved before this layer. Only the fields the slot computation actually
/// reads are modeled here.
public struct ScheduleRow: Equatable, Sendable {
    public let kind: ScheduleKind
    public let intervalHours: Decimal?
    public let timeOfDay: String?
    public let daysOfWeek: [Int]?

    public init(
        kind: ScheduleKind,
        intervalHours: Decimal? = nil,
        timeOfDay: String? = nil,
        daysOfWeek: [Int]? = nil
    ) {
        self.kind = kind
        self.intervalHours = intervalHours
        self.timeOfDay = timeOfDay
        self.daysOfWeek = daysOfWeek
    }
}

/// Mirrors the TS `DoseLogStatus` union (`"taken" | "skipped" | "missed"`,
/// `src/lib/server/db/schema.ts:140`).
public enum DoseStatus: Equatable, Hashable, Sendable {
    case taken
    case skipped
    case missed
}

/// A dose log event as consumed by `computeScheduleSlots`'s slot-matching —
/// lean by design (no dosage/notes/side-effects/medication display fields;
/// those aren't read by the pure computation).
public struct DoseEvent: Equatable, Sendable {
    public let id: String
    public let medicationId: String
    public let takenAt: Date
    public let status: DoseStatus

    public init(id: String, medicationId: String, takenAt: Date, status: DoseStatus) {
        self.id = id
        self.medicationId = medicationId
        self.takenAt = takenAt
        self.status = status
    }
}

// MARK: - Schedule slots

/// Mirrors the TS `ScheduleSlotStatus` union
/// (`"taken" | "skipped" | "upcoming" | "overdue"`, `schedule.ts:4`).
public enum SlotStatus: Equatable, Hashable, Sendable {
    case taken
    case skipped
    case upcoming
    case overdue
}

/// A single expected-dose slot for a medication at a point in time, with its
/// resolved status against the day's dose log. Ports the TS `ScheduleSlot`
/// interface (`schedule.ts:6-17`), dropping the display-only fields
/// (`medicationName`, `colour`, `colourSecondary`, `pattern`,
/// `dosageAmount`, `dosageUnit`) that the pure computation doesn't need.
public struct ScheduleSlot: Equatable, Sendable {
    public let medicationId: String
    public let expectedTime: Date
    public var status: SlotStatus
    public var matchedDoseId: String?

    public init(medicationId: String, expectedTime: Date, status: SlotStatus, matchedDoseId: String? = nil) {
        self.medicationId = medicationId
        self.expectedTime = expectedTime
        self.status = status
        self.matchedDoseId = matchedDoseId
    }
}

// MARK: - Timing status

/// Mirrors the TS `computeTimingStatus` result union
/// (`"ok" | "due_soon" | "due_now" | "overdue"`, `src/lib/utils/time.ts`).
public enum TimingStatus: Equatable, Hashable, Sendable {
    case ok
    case dueSoon
    case dueNow
    case overdue
}

// MARK: - Time-of-day buckets

/// Mirrors the TS `TimeOfDay` union (`"morning" | "afternoon" | "evening" |
/// "night"`, `schedule.ts:19`). Buckets are by **local** hour.
public enum TimeOfDayBucket: Equatable, Hashable, CaseIterable, Sendable {
    case morning
    case afternoon
    case evening
    case night
}

// MARK: - Refill severity

/// Mirrors the TS `RefillSeverity` union (`"critical" | "warning" | "watch" |
/// "ok"`, `src/lib/server/inventory.ts` / `src/lib/types`).
public enum RefillSeverity: Equatable, Hashable, Sendable {
    case critical
    case warning
    case watch
    case ok
}
