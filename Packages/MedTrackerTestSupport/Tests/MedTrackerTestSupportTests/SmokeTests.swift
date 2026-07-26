import Foundation
import Testing
import MedTrackerTestSupport

@Test func mockTransportScriptsAndRecordsRequests() async throws {
    let transport = MockTransport()
    transport.enqueue(status: 200, json: Fixtures.loginSession)
    var req = URLRequest(url: URL(string: "https://x.test/api/v1/auth/login")!)
    req.httpMethod = "POST"
    let (data, resp) = try await transport.send(req)
    #expect(resp.statusCode == 200)
    #expect(String(data: data, encoding: .utf8)!.contains("sess_abc"))
    #expect(transport.requests.count == 1)
}

@Test func fixedClockReturnsPinnedReferenceInstant() {
    #expect(FixedClock.reference.epoch == 1_785_060_000)          // 2026-07-26T10:00:00Z
    #expect(FixedClock(epoch: 0).now == Date(timeIntervalSince1970: 0))
}

@Test func fixturesExposeRecordBuilders() {
    #expect(Fixtures.sampleMedication().id == "m1")
    #expect(Fixtures.sampleDoseLog().medicationId == "m1")
}
