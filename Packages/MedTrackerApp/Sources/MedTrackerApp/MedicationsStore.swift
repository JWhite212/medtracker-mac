import Foundation
import GRDB
import MedTrackerCore
import MedTrackerData
import Observation

/// Medications-list bridge: one `ValueObservation` over `medication` /
/// `medication_schedule` / `dose_log` (+ their aggregation queries) that
/// recomputes both the active and archived card lists into a single
/// `Sendable` snapshot value per emission — mirrors the `DashboardStore`
/// shape (`DashboardStore.swift`). `MedicationsSnapshot.build` is the pure,
/// deterministic seam (fixed `now`/tz in, snapshot out); `observe()` only
/// wires it to the live DB stream.
@MainActor @Observable public final class MedicationsStore {
    public private(set) var active: [MedicationCardVM] = []
    public private(set) var archived: [MedicationCardVM] = []
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
                try MedicationsSnapshot.build(db, userId: userId, now: Date())
            }
            for try await snap in observation.values(in: dbWriter) {
                active = snap.active
                archived = snap.archived
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

public struct TimingBadgeVM: Sendable, Equatable {
    public var status: TimingStatus
    public var minutesUntilDue: Int?

    public init(status: TimingStatus, minutesUntilDue: Int?) {
        self.status = status
        self.minutesUntilDue = minutesUntilDue
    }
}

public struct MedicationCardVM: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var dosageAmount: String
    public var dosageUnit: String
    public var form: String
    public var category: String
    public var colour: String
    public var colourSecondary: String?
    public var pattern: MedicationPattern
    public var textColor: ReadableTextColor
    public var isArchived: Bool
    public var refillSeverity: RefillSeverity
    public var daysUntilRefill: Int?
    public var isLowInventory: Bool
    public var adherencePercent: Double
    public var sparkline: SparklineShape // 14-day
    public var timingBadge: TimingBadgeVM? // §5.2.5 composition

    public init(id: String, name: String, dosageAmount: String, dosageUnit: String, form: String,
                category: String, colour: String, colourSecondary: String?, pattern: MedicationPattern,
                textColor: ReadableTextColor, isArchived: Bool, refillSeverity: RefillSeverity,
                daysUntilRefill: Int?, isLowInventory: Bool, adherencePercent: Double,
                sparkline: SparklineShape, timingBadge: TimingBadgeVM?)
    {
        self.id = id
        self.name = name
        self.dosageAmount = dosageAmount
        self.dosageUnit = dosageUnit
        self.form = form
        self.category = category
        self.colour = colour
        self.colourSecondary = colourSecondary
        self.pattern = pattern
        self.textColor = textColor
        self.isArchived = isArchived
        self.refillSeverity = refillSeverity
        self.daysUntilRefill = daysUntilRefill
        self.isLowInventory = isLowInventory
        self.adherencePercent = adherencePercent
        self.sparkline = sparkline
        self.timingBadge = timingBadge
    }
}

struct MedicationsSnapshot: Sendable {
    var active: [MedicationCardVM]
    var archived: [MedicationCardVM]

    /// Pure recompute over the DB state at `now`. Reads `Profile.timezone`
    /// (UTC fallback); adapts records → lean Core models before every Core
    /// call (§4.1).
    static func build(_ db: Database, userId: String, now: Date) throws -> MedicationsSnapshot {
        let tzID = (try Profile.fetchOne(db))?.timezone ?? "UTC"
        let tz = TimeZone(identifier: tzID) ?? TimeZone(identifier: "UTC")!

        let activeMeds = try Medication.fetchActive(db, userId: userId)
        let archivedMeds = try Medication.fetchArchived(db, userId: userId)
        let schedulesRaw = try MedicationSchedule.groupedByMedication(db, userId: userId)
        let perMed = try DoseAggregations.perMedStats(db, userId: userId, now: now.timeIntervalSince1970)
        var statByMed: [String: PerMedStat] = [:]
        for s in perMed {
            statByMed[s.medicationId] = s
        }

        // 14-day sparkline window: [startOfDay(now-13d), dayEnd).
        let dayStart = startOfDay(now, timeZone: tz)
        let dayEnd = startOfDay(dayStart.addingTimeInterval(26 * 3600), timeZone: tz)
        let sparkFrom = startOfDay(dayStart.addingTimeInterval(-13 * 86_400), timeZone: tz)
        let daily = try DoseAggregations.dailyTakenQuantity(db, userId: userId, tz: tzID,
                                                            fromEpoch: sparkFrom.timeIntervalSince1970, toEpoch: dayEnd.timeIntervalSince1970)

        func cards(_ meds: [Medication]) -> [MedicationCardVM] {
            meds.map { med in
                MedicationCardVM.build(med, schedulesRaw: schedulesRaw[med.id] ?? [],
                                       stat: statByMed[med.id], daily: daily, dayStart: dayStart, tz: tz, tzID: tzID, now: now)
            }
        }
        return MedicationsSnapshot(active: cards(activeMeds), archived: cards(archivedMeds))
    }
}

extension MedicationCardVM {
    static func build(_ med: Medication, schedulesRaw: [MedicationSchedule], stat: PerMedStat?,
                      daily: [DailyDoseCount], dayStart: Date, tz: TimeZone, tzID _: String,
                      now: Date) -> MedicationCardVM
    {
        let scheduleRows = schedulesRaw.map(RecordAdapters.scheduleRow)
        let pattern = RecordAdapters.pattern(med)

        // Refill pipeline (single schedule-aware forecast; never legacy) —
        // dailyRateFor → daysUntilRefill → classifyRefillSeverity.
        let thirty = stat?.thirtyDayQuantity ?? 0
        let rate = dailyRateFor(scheduleRows: scheduleRows, legacyScheduleType: med.scheduleType,
                                legacyIntervalHours: med.scheduleIntervalHoursDecimal, thirtyDayTakenQuantity: thirty)
        // Module-qualified: unqualified `daysUntilRefill` inside this type's own
        // extension resolves to the `MedicationCardVM.daysUntilRefill` property
        // (Swift's type-scope member lookup shadows same-named free functions),
        // not the `MedTrackerCore` free function.
        let days = MedTrackerCore.daysUntilRefill(inventoryCount: med.inventoryCount, dailyRate: rate)
        let severity = classifyRefillSeverity(days: days)
        let isLow = med.inventoryCount != nil && med.inventoryAlertThreshold != nil
            && med.inventoryCount! <= med.inventoryAlertThreshold!

        // Adherence mini-bar: 7-day taken / expected over the effective window.
        let taken7 = stat?.taken7Count ?? 0
        let effDays = clampEffectiveDays(rangeFrom: now.addingTimeInterval(-7 * 86_400), rangeTo: now,
                                         startedAt: Date(timeIntervalSince1970: med.startedAt),
                                         endedAt: med.endedAt.map { Date(timeIntervalSince1970: $0) })
        let expected = jsRound(expectedPerDay(forSchedules: scheduleRows) * Double(effDays))
        // Module-qualified for the same shadowing reason as `daysUntilRefill` above.
        let adherence = MedTrackerCore.adherencePercent(taken: taken7, expected: expected)

        // 14-day sparkline (missing local days → 0).
        var byDay: [String: Int] = [:]
        for c in daily where c.medicationId == med.id {
            byDay[c.localDay] = c.totalQuantity
        }
        var values: [Double] = []
        for i in 0 ..< 14 {
            let day = localDateString(dayStart.addingTimeInterval(Double(i - 13) * 86_400), timeZone: tz)
            values.append(Double(byDay[day] ?? 0))
        }
        let sparkline = buildSparklineShape(values: values, width: 80, height: 24)

        // Timing badge (§5.2.5).
        let lastTaken = stat?.lastTakenAt.map { Date(timeIntervalSince1970: $0) }
        let badge = buildTimingBadge(medId: med.id, scheduleRows: scheduleRows,
                                     lastTaken: lastTaken, tz: tz, now: now)

        return MedicationCardVM(id: med.id, name: med.name, dosageAmount: med.dosageAmount,
                                dosageUnit: med.dosageUnit, form: med.form, category: med.category, colour: med.colour,
                                colourSecondary: med.colourSecondary, pattern: pattern,
                                textColor: getReadableTextColor(colour: med.colour, colourSecondary: med.colourSecondary,
                                                                pattern: pattern),
                                isArchived: med.isArchived, refillSeverity: severity, daysUntilRefill: days,
                                isLowInventory: isLow, adherencePercent: adherence, sparkline: sparkline, timingBadge: badge)
    }
}

/// §5.2.5 composition: interval → `computeTimingStatus`; fixed_time → derive
/// from a 24h `computeScheduleSlots` horizon; interval-never-taken → no
/// badge (kept quirk, §5.2.5 / §15 — matches the web's "no active reminder
/// yet" behaviour rather than surfacing `computeTimingStatus`'s own
/// `(.overdue, -1)` never-taken case).
func buildTimingBadge(medId: String, scheduleRows: [ScheduleRow], lastTaken: Date?,
                      tz: TimeZone, now: Date) -> TimingBadgeVM?
{
    if let interval = scheduleRows.first(where: { $0.kind == .interval && ($0.intervalHours ?? 0) > 0 }),
       let iv = interval.intervalHours
    {
        guard let lastTaken else { return nil } // never taken → no active reminder
        let r = computeTimingStatus(intervalHours: iv, lastEventAt: lastTaken, now: now)
        return TimingBadgeVM(status: r.status, minutesUntilDue: r.minutesUntilDue)
    }
    guard scheduleRows.contains(where: { $0.kind == .fixedTime }) else { return nil }
    let slots = computeScheduleSlots(medications: [medId], schedulesByMedId: [medId: scheduleRows],
                                     todaysDoses: [], lastTakenByMed: [:], dayStart: now,
                                     dayEnd: now.addingTimeInterval(24 * 3600), timeZone: tz, now: now)[medId] ?? []
    if slots.contains(where: { $0.status == .overdue }) {
        return TimingBadgeVM(status: .overdue, minutesUntilDue: nil)
    }
    if let next = slots.filter({ $0.status == .upcoming }).sorted(by: { $0.expectedTime < $1.expectedTime }).first {
        let ms = next.expectedTime.timeIntervalSince(now) * 1000
        return TimingBadgeVM(status: ms <= 3_600_000 ? .dueSoon : .ok, minutesUntilDue: jsRound(ms / 60_000))
    }
    return nil
}

// MARK: - Detail

/// Medication-detail bridge: observes one medication + its schedules + its
/// inventory-event history and republishes them as a single `Sendable`
/// snapshot value (`MedicationDetailVM`) per emission.
@MainActor @Observable public final class MedicationDetailStore {
    public private(set) var detail: MedicationDetailVM?
    public private(set) var loadError: Error?
    private let dbWriter: any DatabaseWriter
    private let userId: String
    private let medicationId: String

    public init(dbWriter: any DatabaseWriter, userId: String, medicationId: String) {
        self.dbWriter = dbWriter
        self.userId = userId
        self.medicationId = medicationId
    }

    /// View-driven: run from the view's `.task { await store.observe() }`.
    /// No stored `Task`, no `deinit` — SwiftUI owns cancellation. A real
    /// stream error lands in `loadError`; `CancellationError` (view
    /// disappeared) is swallowed, not surfaced.
    public func observe() async {
        let userId = userId
        let medicationId = medicationId
        do {
            let observation = ValueObservation.tracking { db in
                try MedicationDetailVM.build(db, userId: userId, medicationId: medicationId, now: Date())
            }
            for try await d in observation.values(in: dbWriter) {
                detail = d
                loadError = nil
            }
        } catch is CancellationError {
            // view disappeared — not an error
        } catch {
            loadError = error
        }
    }
}

/// The SINGLE canonical medication-detail view-model (Reconciliation,
/// AUTHORITATIVE) — owned here in `MedTrackerApp`. The `MedTrackerUI`
/// detail view (Task 22b) must consume this type, not redefine its own.
public struct MedicationDetailVM: Sendable, Equatable, Identifiable {
    public var card: MedicationCardVM
    public var schedules: [ScheduleRow]
    public var inventoryEvents: [InventoryEventVM]
    public var id: String {
        card.id
    }

    public init(card: MedicationCardVM, schedules: [ScheduleRow], inventoryEvents: [InventoryEventVM]) {
        self.card = card
        self.schedules = schedules
        self.inventoryEvents = inventoryEvents
    }

    static func build(_ db: Database, userId: String, medicationId: String,
                      now: Date) throws -> MedicationDetailVM?
    {
        // `Medication.fetchOwned` (MedicationQueries.swift) is `internal` to
        // MedTrackerData, so it's not reachable from this module — inline the
        // same owner-scoped predicate directly via public GRDB API.
        guard let med = try Medication.filter(key: medicationId).filter(Column("user_id") == userId).fetchOne(db)
        else { return nil }
        let tzID = (try Profile.fetchOne(db))?.timezone ?? "UTC"
        let tz = TimeZone(identifier: tzID) ?? TimeZone(identifier: "UTC")!
        let schedulesRaw = (try MedicationSchedule.groupedByMedication(db, userId: userId))[medicationId] ?? []
        let stat = (try DoseAggregations.perMedStats(db, userId: userId, now: now.timeIntervalSince1970))
            .first { $0.medicationId == medicationId }
        let dayStart = startOfDay(now, timeZone: tz)
        let dayEnd = startOfDay(dayStart.addingTimeInterval(26 * 3600), timeZone: tz)
        let sparkFrom = startOfDay(dayStart.addingTimeInterval(-13 * 86_400), timeZone: tz)
        let daily = try DoseAggregations.dailyTakenQuantity(db, userId: userId, tz: tzID,
                                                            fromEpoch: sparkFrom.timeIntervalSince1970, toEpoch: dayEnd.timeIntervalSince1970)
        let card = MedicationCardVM.build(med, schedulesRaw: schedulesRaw, stat: stat, daily: daily,
                                          dayStart: dayStart, tz: tz, tzID: tzID, now: now)
        let events = try InventoryEvent.history(db, userId: userId, medicationId: medicationId).map {
            InventoryEventVM(id: $0.id, eventType: $0.eventType, quantityChange: $0.quantityChange,
                             previousCount: $0.previousCount, newCount: $0.newCount, note: $0.note,
                             createdAt: $0.createdAt)
        }
        return MedicationDetailVM(card: card, schedules: schedulesRaw.map(RecordAdapters.scheduleRow),
                                  inventoryEvents: events)
    }
}

/// Reconciliation — AUTHORITATIVE: `createdAt` is the raw UTC epoch-seconds
/// `Double` (the schema's native timestamp convention, `Schema.swift`), not
/// a `Date` — matches the canonical shape this task's reconciliation note
/// pins down for the Task 22b UI package to consume verbatim.
public struct InventoryEventVM: Sendable, Equatable, Identifiable {
    public var id: String
    public var eventType: String
    public var quantityChange: Int
    public var previousCount: Int?
    public var newCount: Int?
    public var note: String?
    public var createdAt: Double

    public init(id: String, eventType: String, quantityChange: Int, previousCount: Int?, newCount: Int?,
                note: String?, createdAt: Double)
    {
        self.id = id
        self.eventType = eventType
        self.quantityChange = quantityChange
        self.previousCount = previousCount
        self.newCount = newCount
        self.note = note
        self.createdAt = createdAt
    }
}
