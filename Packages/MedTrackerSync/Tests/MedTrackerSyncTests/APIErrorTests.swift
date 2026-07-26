import Foundation
@testable import MedTrackerSync
import Testing

private func body(_ s: String) -> Data {
    Data(s.utf8)
}

@Test func maps400And401And409() {
    #expect(APIError.from(status: 400, data: body(#"{"message":"Invalid"}"#), retryAfterHeader: nil)
        == .badRequest("Invalid"))
    #expect(APIError.from(status: 401, data: body(#"{"message":"Unauthorized"}"#), retryAfterHeader: nil)
        == .unauthorized)
    #expect(APIError.from(status: 409, data: body(#"{"message":"email_conflict"}"#), retryAfterHeader: nil)
        == .emailConflict)
}

@Test func maps429FromBodyThenHeader() {
    #expect(APIError.from(status: 429, data: body(#"{"error":"rate_limited","retryAfterSeconds":42}"#),
                          retryAfterHeader: nil) == .rateLimited(retryAfter: 42))
    // body missing the number -> fall back to Retry-After header
    #expect(APIError.from(status: 429, data: body("{}"), retryAfterHeader: "15")
        == .rateLimited(retryAfter: 15))
}

@Test func maps5xxAndUnknown() {
    #expect(APIError.from(status: 503, data: body("upstream"), retryAfterHeader: nil)
        == .server(status: 503))
}
