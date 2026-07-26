import Foundation
import GRDB
import MedTrackerData
@testable import MedTrackerSync
import Testing

@Test func cursorAndEpochRoundTrip() throws {
    let db = try MedTrackerDatabase.open()
    let store = SyncStateStore(dbWriter: db)
    #expect(try store.loadCursor() == nil)
    #expect(try store.loadEpoch() == 0)
    try store.saveCursor("2026-07-26T10:00:00.000Z")
    try store.saveEpoch(7)
    #expect(try store.loadCursor() == "2026-07-26T10:00:00.000Z")
    #expect(try store.loadEpoch() == 7)
    try store.saveEpoch(8) // overwrite
    #expect(try store.loadEpoch() == 8)
}

@Test func saveCursorAndEpochWritesBothInOneTransaction() throws {
    let db = try MedTrackerDatabase.open()
    let store = SyncStateStore(dbWriter: db)
    try store.saveCursorAndEpoch(cursor: "2026-07-26T11:00:00.000Z", epoch: 3)
    #expect(try store.loadCursor() == "2026-07-26T11:00:00.000Z")
    #expect(try store.loadEpoch() == 3)
    try store.saveCursorAndEpoch(cursor: "2026-07-26T12:00:00.000Z", epoch: 4) // overwrite both
    #expect(try store.loadCursor() == "2026-07-26T12:00:00.000Z")
    #expect(try store.loadEpoch() == 4)
}
