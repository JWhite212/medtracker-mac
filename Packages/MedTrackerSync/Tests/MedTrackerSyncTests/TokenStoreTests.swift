@testable import MedTrackerSync
import Testing

@Test func inMemoryRoundTrips() throws {
    let s = InMemoryTokenStore()
    #expect(try s.load() == nil)
    try s.save(StoredSession(token: "t", userId: "u"))
    #expect(try s.load() == StoredSession(token: "t", userId: "u"))
    try s.clear()
    #expect(try s.load() == nil)
}
