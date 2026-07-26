import Foundation
@testable import MedTrackerSync

final class MockTransport: HTTPTransport, @unchecked Sendable {
    struct Scripted { let status: Int; let body: Data; let headers: [String: String] }
    private var queue: [Scripted] = []
    private(set) var requests: [URLRequest] = []

    func enqueue(status: Int, json: String, headers: [String: String] = [:]) {
        queue.append(.init(status: status, body: Data(json.utf8), headers: headers))
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !queue.isEmpty else { fatalError("MockTransport: no scripted response") }
        let s = queue.removeFirst()
        let resp = HTTPURLResponse(
            url: request.url!, statusCode: s.status,
            httpVersion: nil, headerFields: s.headers
        )!
        return (s.body, resp)
    }

    var lastBodyJSON: [String: Any]? {
        guard let b = requests.last?.httpBody,
              let o = try? JSONSerialization.jsonObject(with: b) as? [String: Any] else { return nil }
        return o
    }
}
