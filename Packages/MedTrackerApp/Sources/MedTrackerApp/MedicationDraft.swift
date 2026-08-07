import Foundation
import MedTrackerCore
import MedTrackerData
import Observation

/// The medication add/edit form's mutable draft state. Lives in the logic
/// package — **no SwiftUI import** — so it can be unit-tested headless and
/// so the UI layer stays a thin renderer over it. `colour`/`colourSecondary`
/// are plain hex `String`s here; the `Binding<Color>` projections SwiftUI's
/// colour wells need are built in the UI layer (Task 22b `StylePicker`),
/// not exposed from this type.
///
/// `.new` starts from sensible defaults; `.edit(id:)` is hydrated after
/// construction via `load(from:schedules:)` since `init(mode:)` itself has
/// no DB access (the contract's `.edit` hydration point).
@MainActor @Observable public final class MedicationDraft {
    public enum Mode: Equatable {
        case new
        case edit(id: String)
    }

    /// One schedule row being edited. `kind` is `"interval"` | `"fixed_time"`
    /// | `"prn"` — the three `MedicationSchedule.scheduleKind` values.
    public struct ScheduleDraft: Identifiable, Equatable, Sendable {
        public var id: String
        public var kind: String
        public var intervalHours: String
        public var timeOfDay: String
        public var daysOfWeek: Set<Int>

        public init(id: String, kind: String, intervalHours: String, timeOfDay: String, daysOfWeek: Set<Int>) {
            self.id = id
            self.kind = kind
            self.intervalHours = intervalHours
            self.timeOfDay = timeOfDay
            self.daysOfWeek = daysOfWeek
        }
    }

    public var mode: Mode
    public var name = ""
    public var dosageAmount = ""
    public var dosageUnit = ""
    public var form = "tablet"
    public var category = "prescription"
    public var colour = "#6366f1"
    public var colourSecondary: String?
    public var pattern: MedicationPattern = .solid
    public var notes = ""
    public var trackInventory = false
    public var inventoryCount = ""
    public var inventoryAlertThreshold = ""
    public var scheduleRows: [ScheduleDraft] = [
        ScheduleDraft(id: createId(), kind: "interval", intervalHours: "", timeOfDay: "", daysOfWeek: []),
    ]

    private static let forms: Set<String> = [
        "tablet", "capsule", "liquid", "softgel", "patch",
        "injection", "inhaler", "drops", "cream", "other",
    ]
    private static let categories: Set<String> = ["prescription", "otc", "supplement"]
    // Held as patterns rather than compiled `NSRegularExpression`s so validation
    // needs no force-try: `range(of:options:.regularExpression)` is non-throwing
    // and these anchored patterns match the same inputs.
    private static let dosageRE = "^\\d+(\\.\\d+)?$"
    private static let timeRE = "^([01]\\d|2[0-3]):[0-5]\\d$"

    public init(mode: Mode) {
        self.mode = mode
    }

    /// `.edit` hydration from persisted records (contract: `.edit` hydrates
    /// from records; `init(mode:)` has no DB access, so callers construct
    /// with `.edit(id:)` and then call this once the records are loaded).
    public func load(from med: Medication, schedules: [MedicationSchedule]) {
        mode = .edit(id: med.id)
        name = med.name
        dosageAmount = med.dosageAmount
        dosageUnit = med.dosageUnit
        form = med.form
        category = med.category
        colour = med.colour
        colourSecondary = med.colourSecondary
        pattern = MedicationPattern(rawValue: med.pattern) ?? .solid
        notes = med.notes ?? ""
        trackInventory = med.inventoryCount != nil
        inventoryCount = med.inventoryCount.map(String.init) ?? ""
        inventoryAlertThreshold = med.inventoryAlertThreshold.map(String.init) ?? ""
        scheduleRows = schedules.sorted { $0.sortOrder < $1.sortOrder }.map { s in
            ScheduleDraft(
                id: s.id, kind: s.scheduleKind,
                intervalHours: s.intervalHours ?? "", timeOfDay: s.timeOfDay ?? "",
                daysOfWeek: Set(s.daysOfWeekArray ?? [])
            )
        }
    }

    // MARK: - Schedule row list editing

    public func addScheduleRow() {
        scheduleRows.append(
            ScheduleDraft(id: createId(), kind: "interval", intervalHours: "", timeOfDay: "", daysOfWeek: [])
        )
    }

    public func removeScheduleRow(at index: Int) {
        guard scheduleRows.indices.contains(index) else { return }
        scheduleRows.remove(at: index)
    }

    // MARK: - Validation

    /// Client-side validation (master §8.1) — the DB `CHECK` constraints are
    /// the backstop; messages here are placeholder copy (§8-#12).
    public func validate() -> [String] {
        var errors: [String] = []
        func matches(_ pattern: String, _ s: String) -> Bool {
            s.range(of: pattern, options: .regularExpression) != nil
        }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.isEmpty || trimmedName.count > 200 {
            errors.append("Name must be 1–200 characters.")
        }
        if !matches(Self.dosageRE, dosageAmount) {
            errors.append("Dosage amount must be a number.")
        }
        if dosageUnit.isEmpty || dosageUnit.count > 20 {
            errors.append("Dosage unit must be 1–20 characters.")
        }
        if notes.count > 1000 {
            errors.append("Notes must be 1000 characters or fewer.")
        }
        if !Self.forms.contains(form) {
            errors.append("Unknown medication form.")
        }
        if !Self.categories.contains(category) {
            errors.append("Unknown medication category.")
        }

        if scheduleRows.isEmpty || scheduleRows.count > 20 {
            errors.append("A medication needs 1–20 schedule rows.")
        }
        for row in scheduleRows {
            switch row.kind {
            case "interval":
                if let h = Double(row.intervalHours), h > 0, h <= 72 {
                    // valid
                } else {
                    errors.append("Interval hours must be greater than 0 and at most 72.")
                }
            case "fixed_time":
                if !matches(Self.timeRE, row.timeOfDay) {
                    errors.append("Time of day must be HH:mm.")
                }
                if row.daysOfWeek.count > 7 || row.daysOfWeek.contains(where: { $0 < 0 || $0 > 6 }) {
                    errors.append("Days of week must be 0–6.")
                }
            case "prn":
                break
            default:
                errors.append("Unknown schedule kind.")
            }
        }

        if trackInventory {
            if let c = Int(inventoryCount), c >= 0 {
                // valid
            } else {
                errors.append("Inventory count must be 0 or more.")
            }
            if !inventoryAlertThreshold.isEmpty,
               !(Int(inventoryAlertThreshold).map { $0 >= 0 } ?? false)
            {
                errors.append("Alert threshold must be 0 or more.")
            }
        }

        return errors
    }

    // MARK: - Projection to save targets

    public func fields() -> MedicationFields {
        let isScheduled = scheduleRows.contains { $0.kind != "prn" }
        let firstInterval = scheduleRows.first { $0.kind == "interval" }?.intervalHours
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        return MedicationFields(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            dosageAmount: dosageAmount,
            dosageUnit: dosageUnit,
            form: form,
            category: category,
            colour: colour,
            colourSecondary: colourSecondary,
            pattern: pattern.rawValue,
            notes: trimmedNotes.isEmpty ? nil : trimmedNotes,
            scheduleType: isScheduled ? "scheduled" : "as_needed",
            scheduleIntervalHours: isScheduled ? firstInterval : nil,
            inventoryCount: trackInventory ? Int(inventoryCount) : nil,
            inventoryAlertThreshold: trackInventory && !inventoryAlertThreshold.isEmpty
                ? Int(inventoryAlertThreshold) : nil
        )
    }

    public func schedules() -> [MedicationScheduleInput] {
        let now = Date()
        return scheduleRows.enumerated().map { index, row in
            let isFixed = row.kind == "fixed_time"
            let isInterval = row.kind == "interval"
            let days = isFixed && !row.daysOfWeek.isEmpty ? row.daysOfWeek.sorted() : nil
            return MedicationScheduleInput(
                scheduleKind: row.kind,
                timeOfDay: isFixed ? row.timeOfDay : nil,
                intervalHours: isInterval ? row.intervalHours : nil,
                daysOfWeek: days,
                sortOrder: index,
                effectiveFrom: now,
                effectiveTo: nil
            )
        }
    }
}
