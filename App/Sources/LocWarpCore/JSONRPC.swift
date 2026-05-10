import Foundation

/// Minimal JSON-RPC 2.0 types used between the Mac app and `locwarpd`.
public enum JSONRPC {
    public static let version = "2.0"

    /// Standard error codes (subset).
    public enum ErrorCode: Int, Sendable {
        case parseError = -32700
        case invalidRequest = -32600
        case methodNotFound = -32601
        case invalidParams = -32602
        case internalError = -32603
    }
}

public struct RPCError: Error, Sendable, CustomStringConvertible {
    public let code: Int
    public let message: String
    public let data: AnyCodable?

    public init(code: Int, message: String, data: AnyCodable? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    public var description: String { "[\(code)] \(message)" }
}

/// A type-erased Codable value used to relay arbitrary JSON-RPC params/results
/// across the wire without forcing a strongly-typed schema for every call.
public struct AnyCodable: Codable, Sendable, Equatable {
    public let value: any Sendable & Codable

    public init<T: Codable & Sendable>(_ value: T) {
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self.value = NullValue(); return }
        if let v = try? c.decode(Bool.self) { self.value = v; return }
        if let v = try? c.decode(Int.self) { self.value = v; return }
        if let v = try? c.decode(Double.self) { self.value = v; return }
        if let v = try? c.decode(String.self) { self.value = v; return }
        if let v = try? c.decode([AnyCodable].self) { self.value = v; return }
        if let v = try? c.decode([String: AnyCodable].self) { self.value = v; return }
        throw DecodingError.dataCorruptedError(
            in: c,
            debugDescription: "Unsupported JSON value for AnyCodable"
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case is NullValue: try c.encodeNil()
        case let v as Bool: try c.encode(v)
        case let v as Int: try c.encode(v)
        case let v as Double: try c.encode(v)
        case let v as String: try c.encode(v)
        case let v as [AnyCodable]: try c.encode(v)
        case let v as [String: AnyCodable]: try c.encode(v)
        default:
            throw EncodingError.invalidValue(
                value,
                EncodingError.Context(
                    codingPath: encoder.codingPath,
                    debugDescription: "Unsupported AnyCodable value"
                )
            )
        }
    }

    public static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        // Best-effort structural equality via JSON encoding.
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return (try? enc.encode(lhs)) == (try? enc.encode(rhs))
    }

    public struct NullValue: Codable, Sendable, Equatable {}
}
