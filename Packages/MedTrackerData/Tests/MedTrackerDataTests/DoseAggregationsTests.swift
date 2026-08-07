import Foundation
import GRDB
@testable import MedTrackerData
import Testing

private let day: Double = 86_400
// 1_700_000_000 == 2023-11-14T22:13:20Z (same UTC calendar day as +3600).
private let base: Double = 1_700_000_000

private func med(_ id: String) -> Medication {
    Medication(id: id, userId: "u1", name: id, dosageAmount: "1", dosageUnit: "mg",
               form: "tablet", category: "otc", colour: "#000000",
               startedAt: base, createdAt: base, updatedAt: base)
}

private func dose(_ id: String, med: String = "m1", qty: Int = 1,
                  takenAt: Double, status: String = "taken") -> DoseLog
{
    DoseLog(id: id, userId: "u1", medicationId: med, quantity: qty,
            takenAt: takenAt, loggedAt: takenAt, status: status, updatedAt: takenAt)
}

struct DoseAggregationsTests {
    @Test func dailyTakenQuantity_groupsByLocalDay_sumsTaken_excludesNonTaken() throws {
        let db = try MedTrackerDatabase.open()
        try db.write { d in
            try med("m1").insert(d)
            try dose("d1", qty: 2, takenAt: base).insert(d) // 2023-11-14
            try dose("d2", qty: 3, takenAt: base + 3600).insert(d) // same UTC day
            try dose("d3", qty: 5, takenAt: base + day).insert(d) // next day
            try dose("d4", qty: 9, takenAt: base, status: "skipped").insert(d) // excluded
        }
        let rows = try db.read {
            try DoseAggregations.dailyTakenQuantity($0, userId: "u1", tz: "UTC",
                                                    fromEpoch: base - day, toEpoch: base + 2 * day)
        }
        try #expect(rows.count == 2)
        try #expect(rows.first(where: { $0.localDay == "2023-11-14" })?.totalQuantity == 5) // 2+3
        try #expect(rows.first(where: { $0.localDay == "2023-11-15" })?.totalQuantity == 5)
    }

    @Test func perMedStats_windowsCountsAndForecast_lastTakenIsMax() throws {
        let db = try MedTrackerDatabase.open()
        let now = base + 30 * day
        try db.write { d in
            try med("m1").insert(d)
            try dose("recent", qty: 1, takenAt: now - 3600).insert(d) // within 7d
            try dose("mid", qty: 4, takenAt: now - 10 * day).insert(d) // in 30d, not 7d
            try dose("skip", qty: 9, takenAt: now - 3600, status: "skipped").insert(d) // excluded
        }
        let stats = try db.read { try DoseAggregations.perMedStats($0, userId: "u1", now: now) }
        try #expect(stats.count == 1)
        let s = try #require(stats.first)
        try #expect(s.medicationId == "m1")
        try #expect(s.taken7Count == 1)
        try #expect(s.thirtyDayQuantity == 5) // 1 + 4
        try #expect(s.lastTakenAt == now - 3600)
    }

    @Test func distinctTakenLocalDates_newestFirst_takenOnly() throws {
        let db = try MedTrackerDatabase.open()
        try db.write { d in
            try med("m1").insert(d)
            try dose("d1", takenAt: base).insert(d) // 2023-11-14
            try dose("d2", takenAt: base + 3600).insert(d) // same day (dedup)
            try dose("d3", takenAt: base + day).insert(d) // 2023-11-15
            try dose("d4", takenAt: base + day, status: "missed").insert(d) // excluded
        }
        let dates = try db.read {
            try DoseAggregations.distinctTakenLocalDatesNewestFirst($0, userId: "u1", tz: "UTC")
        }
        try #expect(dates == ["2023-11-15", "2023-11-14"])
    }
}
