import Foundation

/// An arbitrary-JSON value, used for opaque payloads (`WireCommand.payload`,
/// `WireAuditLog.changes`, command results) that don't have a fixed shape on the wire.
public indirect enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public var stringValue: String? {
        if case let .string(s) = self { return s }
        return nil
    }

    public subscript(_ key: String) -> JSONValue? {
        if case let .object(o) = self { return o[key] }
        return nil
    }

    /// Deep transform: replaces every `.string` value equal to `old` with `new`,
    /// recursing through arrays and objects. Non-string leaves are unchanged.
    public func replacing(_ old: String, with new: String) -> JSONValue {
        switch self {
        case let .string(s):
            return .string(s == old ? new : s)
        case let .array(a):
            return .array(a.map { $0.replacing(old, with: new) })
        case let .object(o):
            return .object(o.mapValues { $0.replacing(old, with: new) })
        default:
            return self
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .number(Double(value))
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case let .bool(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        }
    }
}
