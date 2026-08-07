import Foundation
import GRDB
@testable import MedTrackerData
import Testing

private let base: Double = 1_700_000_000
private let day: Double = 86_400

private func seed(_ db: Database) throws {
    try Medication(id: "m1", userId: "u1", name: "Ibuprofen", dosageAmount: "200",
                   dosageUnit: "mg", form: "tablet", category: "otc", colour: "#ff0000",
                   colourSecondary: nil, pattern: "solid",
                   startedAt: base, createdAt: base, updatedAt: base).insert(db)
    try Medication(id: "m2", userId: "u1", name: "Aspirin", dosageAmount: "75",
                   dosageUnit: "mg", form: "tablet", category: "otc", colour: "#00ff00",
                   isArchived: true, startedAt: base, createdAt: base, updatedAt: base).insert(db)
    try DoseLog(id: "old", userId: "u1", medicationId: "m1", takenAt: base,
                loggedAt: base, notes: "morning dose", status: "taken", updatedAt: base).insert(db)
    try DoseLog(id: "new", userId: "u1", medicationId: "m1", takenAt: base + day,
                loggedAt: base + day, status: "skipped", updatedAt: base + day).insert(db)
    // dose on the ARCHIVED med must still appear (join must not filter is_archived)
    try DoseLog(id: "arch", userId: "u1", medicationId: "m2", takenAt: base + 2 * day,
                loggedAt: base + 2 * day,
                sideEffects: [SideEffectEntry(name: "nausea", severity: "mild")],
                status: "taken", updatedAt: base + 2 * day).insert(db)
}

struct DoseLogQueriesTests {
    @Test func page_joinsMedication_ordersTakenDesc_includesArchivedMed() throws {
        let db = try MedTrackerDatabase.open()
        try db.write { try seed($0) }
        let rows = try db.read {
            try DoseLogQueries.page($0, userId: "u1", tz: "UTC", filter: HistoryFilter(), limit: 20)
        }
        try #expect(rows.map(\.doseId) == ["arch", "new", "old"]) // taken_at DESC
        try #expect(rows.first?.medicationName == "Aspirin") // archived med joined
        try #expect(rows.last?.localDay == "2023-11-14")
    }

    @Test func page_appliesOptionalFilters() throws {
        let db = try MedTrackerDatabase.open()
        try db.write { try seed($0) }
        func page(_ f: HistoryFilter) throws -> [String] {
            try db.read { try DoseLogQueries.page($0, userId: "u1", tz: "UTC", filter: f, limit: 20) }
                .map(\.doseId)
        }
        try #expect(page(HistoryFilter(status: "skipped")) == ["new"])
        try #expect(page(HistoryFilter(medicationId: "m2")) == ["arch"])
        try #expect(page(HistoryFilter(fromEpoch: base + day, toEpoch: base + 2 * day)) == ["new"])
        try #expect(page(HistoryFilter(notesQuery: "morning")) == ["old"])
        try #expect(page(HistoryFilter(sideEffectName: "nausea")) == ["arch"])
        try #expect(page(HistoryFilter(sideEffectSeverity: "mild")) == ["arch"])
    }

    @Test func page_growingLimitCaps() throws {
        let db = try MedTrackerDatabase.open()
        try db.write { try seed($0) }
        let rows = try db.read {
            try DoseLogQueries.page($0, userId: "u1", tz: "UTC", filter: HistoryFilter(), limit: 2)
        }
        try #expect(rows.map(\.doseId) == ["arch", "new"])
    }
}
