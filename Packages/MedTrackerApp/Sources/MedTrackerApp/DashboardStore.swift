import Foundation
import GRDB
import MedTrackerCore
import MedTrackerData
import Observation

/// Dashboard bridge: one `ValueObservation` over `medication` /
/// `medication_schedule` / `dose_log` (+ their aggregation queries) that
/// recomputes the whole dashboard derived tree — SummaryStrip, RefillsCard,
/// QuickLogBar, MyDayTimeline, TodayFeed — into a single `Sendable` snapshot
/// value per emission. `DashboardSnapshot.build` is the pure, deterministic
/// seam (fixed `now`/tz in, snapshot out); `observe()` only wires it to the
/// live DB stream.
@MainActor @Observable public final class DashboardStore {
    public private(set) var snapshot = DashboardSnapshot.empty
    public private(set) var loadError: Error?
    private let dbWriter: any DatabaseWriter
    private let userId: String

    public init(dbWriter: any DatabaseWriter, userId: String) {
        self.dbWriter = dbWriter
        self.userId = userId
    }

    /// View-driven: run from the view's `.task { await store.observe() }`.
    /// No stored `Task`, no `deinit` — SwiftUI owns cancellation. A real
    /// stream error lands in `loadError`; `CancellationError` (view
    /// disappeared) is swallowed, not surfaced.
    public func observe() async {
        let userId = userId
        do {
            let observation = ValueObservation.tracking { db in
                try DashboardSnapshot.build(db, userId: userId, now: Date())
            }
            for try await snap in observation.values(in: dbWriter) {
                snapshot = snap
                loadError = nil
            }
        } catch is CancellationError {
            // view disappeared — not an error
        } catch {
            loadError = error
        }
    }
}

// MARK: - Sendable snapshot value types

public struct SummaryStripVM: Sendable, Equatable {
    public var takenCount: Int
    public var scheduledCount: Int
    public var adherencePercent: Double
    public var streak: Int
    public init(takenCount: Int, scheduledCount: Int, adherencePercent: Double, streak: Int) {
        self.takenCount = takenCount
        self.scheduledCount = scheduledCount
        self.adherencePercent = adherencePercent
        self.streak = streak
    }
}

public struct RefillRowVM: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var colour: String
    public var colourSecondary: String?
    public var pattern: MedicationPattern
    public var severity: RefillSeverity
    public var daysUntilRefill: Int?
    public var isLowInventory: Bool
    public init(id: String, name: String, colour: String, colourSecondary: String?,
                pattern: MedicationPattern, severity: RefillSeverity,
                daysUntilRefill: Int?, isLowInventory: Bool)
    {
        self.id = id
        self.name = name
        self.colour = colour
        self.colourSecondary = colourSecondary
        self.pattern = pattern
        self.severity = severity
        self.daysUntilRefill = daysUntilRefill
        self.isLowInventory = isLowInventory
    }
}

public struct QuickLogItemVM: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var colour: String
    public var colourSecondary: String?
    public var pattern: MedicationPattern
    public var textColor: ReadableTextColor
    public init(id: String, name: String, colour: String, colourSecondary: String?,
                pattern: MedicationPattern, textColor: ReadableTextColor)
    {
        self.id = id
        self.name = name
        self.colour = colour
        self.colourSecondary = colourSecondary
        self.pattern = pattern
        self.textColor = textColor
    }
}

public struct MyDaySlotVM: Sendable, Equatable, Identifiable {
    public var id: String
    public var medicationId: String
    public var name: String
    public var colour: String
    public var colourSecondary: String?
    public var pattern: MedicationPattern
    public var expectedTime: Date
    public var status: SlotStatus
    public init(id: String, medicationId: String, name: String, colour: String,
                colourSecondary: String?, pattern: MedicationPattern,
                expectedTime: Date, status: SlotStatus)
    {
        self.id = id
        self.medicationId = medicationId
        self.name = name
        self.colour = colour
        self.colourSecondary = colourSecondary
        self.pattern = pattern
        self.expectedTime = expectedTime
        self.status = status
    }
}

public struct MyDayBucketVM: Sendable, Equatable, Identifiable {
    public var id: String
    public var bucket: TimeOfDayBucket
    public var slots: [MyDaySlotVM]
    public init(id: String, bucket: TimeOfDayBucket, slots: [MyDaySlotVM]) {
        self.id = id
        self.bucket = bucket
        self.slots = slots
    }
}

public struct TodayFeedRowVM: Sendable, Equatable, Identifiable {
    public var id: String
    public var medicationId: String
    public var name: String
    public var colour: String
    public var colourSecondary: String?
    public var pattern: MedicationPattern
    public var expectedTime: Date
    public var lastTakenAt: Date?
    public init(id: String, medicationId: String, name: String, colour: String,
                colourSecondary: String?, pattern: MedicationPattern,
                expectedTime: Date, lastTakenAt: Date?)
    {
        self.id = id
        self.medicationId = medicationId
        self.name = name
        self.colour = colour
        self.colourSecondary = colourSecondary
        self.pattern = pattern
        self.expectedTime = expectedTime
        self.lastTakenAt = lastTakenAt
    }
}

public struct DashboardSnapshot: Sendable, Equatable {
    public var timeZoneID: String
    public var isEmpty: Bool
    public var summary: SummaryStripVM
    public var refills: [RefillRowVM]
    public var quickLog: [QuickLogItemVM]
    public var myDay: [MyDayBucketVM]
    public var todayFeed: [TodayFeedRowVM]

    public init(timeZoneID: String, isEmpty: Bool, summary: SummaryStripVM,
                refills: [RefillRowVM], quickLog: [QuickLogItemVM],
                myDay: [MyDayBucketVM], todayFeed: [TodayFeedRowVM])
    {
        self.timeZoneID = timeZoneID
        self.isEmpty = isEmpty
        self.summary = summary
        self.refills = refills
        self.quickLog = quickLog
        self.myDay = myDay
        self.todayFeed = todayFeed
    }

    public static let empty = DashboardSnapshot(
        timeZoneID: "UTC", isEmpty: true,
        summary: SummaryStripVM(takenCount: 0, scheduledCount: 0, adherencePercent: 0, streak: 0),
        refills: [], quickLog: [], myDay: [], todayFeed: []
    )

    /// Pure recompute over the DB state at `now`. Reads `Profile.timezone`
    /// (UTC fallback); adapts records → lean Core models before every Core call.
    public static func build(_ db: Database, userId: String, now: Date) throws -> DashboardSnapshot {
        let tzID = (try Profile.fetchOne(db))?.timezone ?? "UTC"
        let tz = TimeZone(identifier: tzID) ?? TimeZone(identifier: "UTC")!

        let activeMeds = try Medication.fetchActive(db, userId: userId) // ordered sort_order
        guard !activeMeds.isEmpty else {
            return DashboardSnapshot(timeZoneID: tzID, isEmpty: true,
                                     summary: SummaryStripVM(takenCount: 0, scheduledCount: 0, adherencePercent: 0, streak: 0),
                                     refills: [], quickLog: [], myDay: [], todayFeed: [])
        }
        let activeIds = activeMeds.map(\.id)
        let medByID = Dictionary(uniqueKeysWithValues: activeMeds.map { ($0.id, $0) })

        let dayStart = startOfDay(now, timeZone: tz)
        let dayEnd = startOfDay(dayStart.addingTimeInterval(26 * 3600), timeZone: tz)
        let nowEpoch = now.timeIntervalSince1970

        // Effective-window-filtered, adapted schedule rows.
        let allSchedules = try MedicationSchedule.groupedByMedication(db, userId: userId)
        var schedulesByMedId: [String: [ScheduleRow]] = [:]
        for medId in activeIds {
            let rows = (allSchedules[medId] ?? []).filter { s in
                s.effectiveFrom <= nowEpoch && (s.effectiveTo == nil || s.effectiveTo! > nowEpoch)
            }
            schedulesByMedId[medId] = rows.map(RecordAdapters.scheduleRow)
        }

        let todaysDoses = try DoseLog
            .filter(Column("user_id") == userId)
            .filter(Column("taken_at") >= dayStart.timeIntervalSince1970)
            .filter(Column("taken_at") < dayEnd.timeIntervalSince1970)
            .fetchAll(db)
            .map(RecordAdapters.doseEvent)

        let perMed = try DoseAggregations.perMedStats(db, userId: userId, now: nowEpoch)
        var lastTakenByMed: [String: Date] = [:]
        var statByMed: [String: PerMedStat] = [:]
        for s in perMed {
            statByMed[s.medicationId] = s
            if let lt = s.lastTakenAt { lastTakenByMed[s.medicationId] = Date(timeIntervalSince1970: lt) }
        }

        let slotsByMed = computeScheduleSlots(
            medications: activeIds, schedulesByMedId: schedulesByMedId,
            todaysDoses: todaysDoses, lastTakenByMed: lastTakenByMed,
            dayStart: dayStart, dayEnd: dayEnd, timeZone: tz, now: now
        )
        let allSlots = activeIds.flatMap { slotsByMed[$0] ?? [] }

        // SummaryStrip
        let scheduledCount = allSlots.count
        let takenCount = allSlots.filter { $0.status == .taken }.count
        let dueSoFar = allSlots.filter { $0.expectedTime <= now }.count // CONFIRM §8-#12
        let adherence = adherencePercent(taken: takenCount, expected: dueSoFar)
        let streakDates = try DoseAggregations.distinctTakenLocalDatesNewestFirst(db, userId: userId, tz: tzID)
        let streak = calculateStreak(dateStringsNewestFirst: streakDates,
                                     today: localDateString(now, timeZone: tz))
        let summary = SummaryStripVM(takenCount: takenCount, scheduledCount: scheduledCount,
                                     adherencePercent: adherence, streak: streak)

        // RefillsCard (non-ok severity), sorted days ascending.
        var refills: [RefillRowVM] = []
        for med in activeMeds {
            let rows = schedulesByMedId[med.id] ?? []
            let thirty = statByMed[med.id]?.thirtyDayQuantity ?? 0
            let rate = dailyRateFor(scheduleRows: rows, legacyScheduleType: med.scheduleType,
                                    legacyIntervalHours: med.scheduleIntervalHoursDecimal,
                                    thirtyDayTakenQuantity: thirty)
            let days = daysUntilRefill(inventoryCount: med.inventoryCount, dailyRate: rate)
            let severity = classifyRefillSeverity(days: days)
            guard severity != .ok else { continue }
            let isLow = med.inventoryCount != nil && med.inventoryAlertThreshold != nil
                && med.inventoryCount! <= med.inventoryAlertThreshold!
            refills.append(RefillRowVM(id: med.id, name: med.name, colour: med.colour,
                                       colourSecondary: med.colourSecondary, pattern: RecordAdapters.pattern(med),
                                       severity: severity, daysUntilRefill: days, isLowInventory: isLow))
        }
        refills.sort { ($0.daysUntilRefill ?? .max) < ($1.daysUntilRefill ?? .max) }

        // QuickLogBar
        let quickLog = activeMeds.map { med -> QuickLogItemVM in
            let pattern = RecordAdapters.pattern(med)
            return QuickLogItemVM(id: med.id, name: med.name, colour: med.colour,
                                  colourSecondary: med.colourSecondary, pattern: pattern,
                                  textColor: getReadableTextColor(colour: med.colour,
                                                                  colourSecondary: med.colourSecondary, pattern: pattern))
        }

        // MyDay
        let myDay = groupSlotsByTimeOfDay(allSlots, timeZone: tz).map { bucket, slots in
            MyDayBucketVM(id: bucketID(bucket), bucket: bucket, slots: slots.map { slot in
                let med = medByID[slot.medicationId]!
                return MyDaySlotVM(id: slotID(slot), medicationId: slot.medicationId, name: med.name,
                                   colour: med.colour, colourSecondary: med.colourSecondary,
                                   pattern: RecordAdapters.pattern(med), expectedTime: slot.expectedTime, status: slot.status)
            })
        }

        // TodayFeed (overdue slots, earliest first)
        let todayFeed = allSlots.filter { $0.status == .overdue }
            .sorted { $0.expectedTime < $1.expectedTime }
            .map { slot -> TodayFeedRowVM in
                let med = medByID[slot.medicationId]!
                return TodayFeedRowVM(id: slotID(slot), medicationId: slot.medicationId, name: med.name,
                                      colour: med.colour, colourSecondary: med.colourSecondary,
                                      pattern: RecordAdapters.pattern(med), expectedTime: slot.expectedTime,
                                      lastTakenAt: lastTakenByMed[slot.medicationId])
            }

        return DashboardSnapshot(timeZoneID: tzID, isEmpty: false, summary: summary,
                                 refills: refills, quickLog: quickLog, myDay: myDay, todayFeed: todayFeed)
    }
}

private func slotID(_ s: ScheduleSlot) -> String {
    "\(s.medicationId)-\(Int(s.expectedTime.timeIntervalSince1970))"
}

private func bucketID(_ b: TimeOfDayBucket) -> String {
    switch b {
    case .morning: return "morning"
    case .afternoon: return "afternoon"
    case .evening: return "evening"
    case .night: return "night"
    }
}
