import Foundation
import GRDB
import MedTrackerCore
import MedTrackerData
import MedTrackerSync
import Observation

/// Identity key for the growing-window `.task(id:)` seam (§2.6): the view binds
/// `.task(id: store.observationKey) { await store.observe() }`; mutating `filter`
/// or calling `loadMore()` changes this value, so SwiftUI cancels the running
/// `observe()` and restarts it fresh.
public struct HistoryObservationKey: Hashable, Sendable {
    public var filter: HistoryFilter
    public var limit: Int
}

/// `HistoryRow` (raw GRDB projection) adapted into a lean, `Sendable` view-model:
/// `sideEffects` decoded from its JSON-text column, `pattern`/`status` adapted via
/// `MedicationPattern(rawValue:)` / `RecordAdapters.doseStatus`, `textColor` precomputed.
public struct HistoryRowVM: Sendable, Equatable, Identifiable {
    public var id: String
    public var medicationId: String
    public var medicationName: String
    public var dosageAmount: String
    public var dosageUnit: String
    public var colour: String
    public var colourSecondary: String?
    public var pattern: MedicationPattern
    public var textColor: ReadableTextColor
    public var quantity: Int
    public var takenAt: Date
    public var status: DoseStatus
    public var notes: String?
    public var sideEffects: [SideEffectEntry]
}

/// One calendar-day group of history rows, newest-day-first (inherited from the
/// `taken_at DESC` page query).
public struct HistorySection: Sendable, Equatable, Identifiable {
    public var id: String
    public var label: String
    public var rows: [HistoryRowVM]

    struct Result: Sendable {
        var sections: [HistorySection]
        var hasMore: Bool
    }

    /// Pure page → grouped sections (newest-first day order preserved from the
    /// `taken_at DESC` query). Today/Yesterday compared in `Profile.timezone`;
    /// anything else renders an absolute date via a `DateFormatter` built from
    /// the synced `Settings.dateFormat` (read-only in 1c per master §15 — "implement
    /// it" — NOT the Phase-2-deferred stub; never a hardcoded `.medium` style).
    static func build(_ db: Database, userId: String, filter: HistoryFilter, limit: Int,
                      now: Date) throws -> Result
    {
        let tzID = (try Profile.fetchOne(db))?.timezone ?? "UTC"
        let tz = TimeZone(identifier: tzID) ?? TimeZone(identifier: "UTC")!
        let dateFormat = (try Settings.fetchOne(db, key: 1))?.dateFormat ?? "DD/MM/YYYY"
        let rows = try DoseLogQueries.page(db, userId: userId, tz: tzID, filter: filter, limit: limit)
        let hasMore = rows.count == limit

        var order: [String] = []
        var byDay: [String: [HistoryRowVM]] = [:]
        for row in rows {
            if byDay[row.localDay] == nil { order.append(row.localDay) }
            byDay[row.localDay, default: []].append(vm(row))
        }
        let today = localDateString(now, timeZone: tz)
        let yesterday = localDateString(startOfDay(now, timeZone: tz).addingTimeInterval(-1), timeZone: tz)
        let sections = order.map { day in
            HistorySection(id: day,
                           label: label(for: day, today: today, yesterday: yesterday,
                                        tz: tz, dateFormat: dateFormat),
                           rows: byDay[day]!)
        }
        return Result(sections: sections, hasMore: hasMore)
    }

    private static func vm(_ r: HistoryRow) -> HistoryRowVM {
        let pattern = MedicationPattern(rawValue: r.pattern) ?? .solid
        let sideEffects: [SideEffectEntry] = r.sideEffects
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode([SideEffectEntry].self, from: $0) } ?? []
        return HistoryRowVM(id: r.doseId, medicationId: r.medicationId, medicationName: r.medicationName,
                            dosageAmount: r.dosageAmount, dosageUnit: r.dosageUnit, colour: r.colour,
                            colourSecondary: r.colourSecondary, pattern: pattern,
                            textColor: getReadableTextColor(colour: r.colour, colourSecondary: r.colourSecondary,
                                                            pattern: pattern),
                            quantity: r.quantity, takenAt: Date(timeIntervalSince1970: r.takenAt),
                            status: RecordAdapters.doseStatus(r.status), notes: r.notes,
                            sideEffects: sideEffects)
    }

    private static func label(for day: String, today: String, yesterday: String,
                              tz: TimeZone, dateFormat: String) -> String
    {
        if day == today { return "Today" }
        if day == yesterday { return "Yesterday" }
        let parser = DateFormatter()
        parser.calendar = Calendar(identifier: .gregorian)
        parser.timeZone = tz
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: day) else { return day }
        let out = DateFormatter()
        out.timeZone = tz
        out.dateFormat = datePattern(for: dateFormat)
        return out.string(from: date)
    }

    /// Maps the synced `Settings.dateFormat` value (`"DD/MM/YYYY" | "MM/DD/YYYY" |
    /// "YYYY-MM-DD"`, api-v1-contract.md:313) to a `DateFormatter.dateFormat`
    /// pattern. An unrecognized value falls back to the column's own default
    /// (`"DD/MM/YYYY"`) rather than trapping.
    private static func datePattern(for dateFormat: String) -> String {
        switch dateFormat {
        case "MM/DD/YYYY": return "MM/dd/yyyy"
        case "YYYY-MM-DD": return "yyyy-MM-dd"
        default: return "dd/MM/yyyy" // "DD/MM/YYYY" and any unrecognized value
        }
    }
}

/// History screen bridge: filter state, a growing-window live paged
/// `ValueObservation` over `DoseLogQueries.page`, and the edit/delete write
/// wrappers that route through the (private) `WriteCoordinator`.
@MainActor @Observable public final class HistoryStore {
    public private(set) var sections: [HistorySection] = []
    public private(set) var hasMore = false
    public private(set) var loadError: Error?
    public var filter = HistoryFilter() {
        didSet { if filter != oldValue { loadedPages = 1 } }
    }

    public private(set) var loadedPages = 1

    private let dbWriter: any DatabaseWriter
    private let userId: String
    private let writeCoordinator: WriteCoordinator
    private let pageSize: Int

    public init(dbWriter: any DatabaseWriter, userId: String,
                writeCoordinator: WriteCoordinator, pageSize: Int = 20)
    {
        self.dbWriter = dbWriter
        self.userId = userId
        self.writeCoordinator = writeCoordinator
        self.pageSize = pageSize
    }

    /// Identity key for the view's `.task(id:)` (§2.6) — `filter`/`loadMore()`
    /// mutate it, so SwiftUI cancels + restarts `observe()`. Uses the
    /// constructor's `pageSize` (not `Settings.doseLogPageSize`, which
    /// `observe()` re-reads reactively on every emission below) since a task
    /// identity must be computed synchronously with no DB access.
    public var observationKey: HistoryObservationKey {
        HistoryObservationKey(filter: filter, limit: loadedPages * pageSize)
    }

    /// Increments the growing window; `filter`'s `didSet` resets it back to 1.
    public func loadMore() {
        loadedPages += 1
    }

    /// View-driven: run from the view's `.task(id: observationKey) { await
    /// store.observe() }`. No stored `Task`, no `deinit` — SwiftUI owns
    /// cancellation. `filter`/`loadedPages` are captured fresh at entry (the
    /// `.task(id:)` restart is what picks up a later change). A real stream
    /// error lands in `loadError`; `CancellationError` (view disappeared) is
    /// swallowed, not surfaced.
    public func observe() async {
        let userId = userId
        let filter = filter
        let loadedPages = loadedPages
        let pageSize = pageSize
        do {
            let observation = ValueObservation.tracking { db -> HistorySection.Result in
                // `doseLogPageSize` (default 20 only when the Settings row is
                // absent) read fresh on every emission — reading it here (rather
                // than baking it into `observationKey`) also makes the live
                // window reactive to a Settings change without a `.task` restart.
                let effectivePageSize = try Settings.fetchOne(db, key: 1)?.doseLogPageSize ?? pageSize
                let limit = loadedPages * effectivePageSize
                return try HistorySection.build(db, userId: userId, filter: filter, limit: limit, now: Date())
            }
            for try await result in observation.values(in: dbWriter) {
                sections = result.sections
                hasMore = result.hasMore
                loadError = nil
            }
        } catch is CancellationError {
            // view disappeared — not an error
        } catch {
            loadError = error
        }
    }

    /// Routes through the (private) `WriteCoordinator` — the optimistic local
    /// mutation + outbox enqueue happen in one transaction there (Task 10);
    /// the live `observe()` stream reflects the change on its next emission.
    public func editDose(doseId: String, takenAt: Date?, quantity: Int?,
                         notes: String??, sideEffects: [SideEffectEntry]??) async throws
    {
        try await writeCoordinator.editDose(doseId: doseId, takenAt: takenAt, quantity: quantity,
                                            notes: notes, sideEffects: sideEffects)
    }

    public func deleteDose(doseId: String) async throws {
        try await writeCoordinator.deleteDose(doseId: doseId)
    }
}
