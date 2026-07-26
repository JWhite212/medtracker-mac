import Foundation

/// Typed error surface for `/api/v1` responses (contract §6). The contract defines two
/// distinct error body shapes: `{message}` for 400/401/409, and
/// `{error:"rate_limited",retryAfterSeconds}` for 429.
public enum APIError: Error, Equatable, Sendable {
    case badRequest(String)
    case unauthorized
    case emailConflict
    case rateLimited(retryAfter: Int)
    case server(status: Int)
    case transport(String)
    case decoding(String)

    private struct MessageBody: Decodable {
        let message: String?
    }

    private struct RateBody: Decodable {
        let error: String?
        let retryAfterSeconds: Int?
    }

    /// Maps a non-2xx HTTP response to a typed `APIError`, decoding whichever of the two
    /// contract §6 body shapes applies to `status`.
    public static func from(status: Int, data: Data, retryAfterHeader: String?) -> APIError {
        switch status {
        case 400:
            let message = try? JSONDecoder().decode(MessageBody.self, from: data).message
            return .badRequest(message ?? "")
        case 401:
            return .unauthorized
        case 409:
            let message = try? JSONDecoder().decode(MessageBody.self, from: data).message
            return message == "email_conflict" ? .emailConflict : .badRequest(message ?? "")
        case 429:
            let rateBody = try? JSONDecoder().decode(RateBody.self, from: data)
            let retryAfter = rateBody?.retryAfterSeconds ?? Int(retryAfterHeader ?? "") ?? 0
            return .rateLimited(retryAfter: retryAfter)
        default:
            return .server(status: status)
        }
    }
}
