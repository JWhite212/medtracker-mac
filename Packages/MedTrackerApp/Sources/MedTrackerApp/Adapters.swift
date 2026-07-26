import Foundation
import MedTrackerCore
import MedTrackerData

/// Record → lean Core-model adapters (§4.1). Every store and the WriteCoordinator route through
/// these before any `MedTrackerCore` call — the single, unit-tested seam between the persistence
/// records (raw `String`/epoch-`Double`) and the pure domain models Core computes over.
public enum RecordAdapters {
    /// `MedicationSchedule` → `ScheduleRow`. Unknown `scheduleKind` → `.prn` (inert: prn contributes
    /// no scheduled slots), so a corrupt row degrades safely rather than trapping.
    public static func scheduleRow(_ r: MedicationSchedule) -> ScheduleRow {
        ScheduleRow(kind: ScheduleKind(rawValue: r.scheduleKind) ?? .prn,
                    intervalHours: r.intervalHoursDecimal,
                    timeOfDay: r.timeOfDay,
                    daysOfWeek: r.daysOfWeekArray)
    }

    /// `DoseLog` → `DoseEvent`. `takenAt` epoch-seconds → `Date`; `status` via `doseStatus`.
    public static func doseEvent(_ d: DoseLog) -> DoseEvent {
        DoseEvent(id: d.id,
                  medicationId: d.medicationId,
                  takenAt: Date(timeIntervalSince1970: d.takenAt),
                  status: doseStatus(d.status))
    }

    /// `Medication.pattern` raw → `MedicationPattern`; unknown → `.solid`.
    public static func pattern(_ m: Medication) -> MedicationPattern {
        MedicationPattern(rawValue: m.pattern) ?? .solid
    }

    /// Dose-log status raw → `DoseStatus`. Only `"skipped"`/`"missed"` are distinguished;
    /// everything else (including a stored `"taken"`) maps to `.taken` (§4.1).
    public static func doseStatus(_ raw: String) -> DoseStatus {
        switch raw {
        case "skipped": return .skipped
        case "missed": return .missed
        default: return .taken
        }
    }
}
