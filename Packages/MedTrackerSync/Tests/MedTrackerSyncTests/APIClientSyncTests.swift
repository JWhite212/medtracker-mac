import Foundation
@testable import MedTrackerSync
import MedTrackerTestSupport
import Testing

private func client(_ t: MockTransport) -> APIClient {
    APIClient(config: SyncConfig(baseURL: URL(string: "https://x.test/api/v1")!), transport: t)
}

@Test func syncSendsCursorEpochAndBearer() async throws {
    let t = MockTransport(); t.enqueue(status: 200, json: Fixtures.syncDelta)
    let r = try await client(t).sync(since: "2026-07-26T09:00:00.000Z", epoch: 2, token: "sess_abc")
    #expect(r.medications.count == 1)
    let url = t.requests.last!.url!
    let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
    #expect(url.path == "/api/v1/sync")
    #expect(comps.queryItems?.first { $0.name == "since" }?.value == "2026-07-26T09:00:00.000Z")
    #expect(comps.queryItems?.first { $0.name == "epoch" }?.value == "2")
    #expect(t.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer sess_abc")
}

@Test func syncOmitsSinceWhenNil() async throws {
    let t = MockTransport(); t.enqueue(status: 200, json: Fixtures.syncDelta)
    _ = try await client(t).sync(since: nil, epoch: 0, token: "tok")
    let comps = URLComponents(url: t.requests.last!.url!, resolvingAgainstBaseURL: false)!
    #expect(comps.queryItems?.contains { $0.name == "since" } != true)
}

@Test func syncUnauthorizedThrows() async throws {
    let t = MockTransport(); t.enqueue(status: 401, json: #"{"message":"Unauthorized"}"#)
    await #expect(throws: APIError.unauthorized) {
        _ = try await client(t).sync(since: nil, epoch: 0, token: "stale")
    }
}

@Test func runCommandsReturnsResults() async throws {
    let t = MockTransport()
    t.enqueue(status: 200, json: #"{"results":[{"id":"k1","ok":true,"result":{"id":"srvDose1"}}]}"#)
    let resp = try await client(t).runCommands(
        [WireCommand(id: "k1", type: "log_dose", payload: .object(["medicationId": .string("m1")]))],
        token: "tok"
    )
    #expect(resp.results[0].ok)
    #expect(resp.results[0].result?["id"]?.stringValue == "srvDose1")
    #expect(t.lastBodyJSON?["commands"] != nil)
}
