import Foundation
import MedTrackerSync

/// Scriptable `HTTPTransport` test double: enqueue `(status, json)` responses in FIFO
/// order, then assert against the recorded `requests` (and `lastBodyJSON`). No network.
public final class MockTransport: HTTPTransport, @unchecked Sendable {
    public struct Scripted {
        public let status: Int
        public let body: Data
        public let headers: [String: String]
    }

    private var queue: [Scripted] = []
    public private(set) var requests: [URLRequest] = []

    public init() {}

    public func enqueue(status: Int, json: String, headers: [String: String] = [:]) {
        queue.append(.init(status: status, body: Data(json.utf8), headers: headers))
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !queue.isEmpty else { fatalError("MockTransport: no scripted response") }
        let scripted = queue.removeFirst()
        let resp = HTTPURLResponse(
            url: request.url!, statusCode: scripted.status,
            httpVersion: nil, headerFields: scripted.headers
        )!
        return (scripted.body, resp)
    }

    public var lastBodyJSON: [String: Any]? {
        guard let body = requests.last?.httpBody,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else { return nil }
        return object
    }
}
