import Foundation

/// A JSON value stored on an entity or a link.
///
/// Importers keep unknown columns here so a later graph view can show them
/// without IntelKit knowing the column in advance.
public enum JSONValue: Sendable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var number: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    public var bool: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
            return
        }
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
            return
        }
        if let value = try? container.decode(Double.self) {
            self = .number(value)
            return
        }
        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }
        if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
            return
        }
        if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Unsupported JSON value"
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            if value.isFinite,
                value.rounded() == value,
                value <= Double(Int64.max),
                value >= Double(Int64.min)
            {
                try container.encode(Int64(value))
            } else {
                try container.encode(value)
            }
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral
{
    public init(stringLiteral value: String) {
        self = .string(value)
    }

    public init(integerLiteral value: Int) {
        self = .number(Double(value))
    }

    public init(floatLiteral value: Double) {
        self = .number(value)
    }

    public init(booleanLiteral value: Bool) {
        self = .bool(value)
    }
}

enum JSONCodec {
    static func encodeObject(_ properties: [String: JSONValue]) throws -> String {
        let data = try JSONEncoder().encode(properties)
        return String(decoding: data, as: UTF8.self)
    }

    static func decodeObject(_ text: String) throws -> [String: JSONValue] {
        guard let data = text.data(using: .utf8) else {
            throw IntelError.database("Property JSON was not UTF-8")
        }
        return try JSONDecoder().decode([String: JSONValue].self, from: data)
    }

    /// Converts a `JSONSerialization` result into ``JSONValue``.
    static func value(from any: Any) -> JSONValue {
        if any is NSNull {
            return .null
        }
        if let value = any as? Bool {
            return .bool(value)
        }
        if let value = any as? NSNumber {
            return .number(value.doubleValue)
        }
        if let value = any as? String {
            return .string(value)
        }
        if let value = any as? [Any] {
            return .array(value.map(self.value(from:)))
        }
        if let value = any as? [String: Any] {
            return .object(value.mapValues(self.value(from:)))
        }
        return .string(String(describing: any))
    }
}
