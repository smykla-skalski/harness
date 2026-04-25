import Foundation

/// Recursive JSON value used for passthrough fields (git/system/targets blocks) where the
/// shape is determined by upstream tools and not worth modelling.
public indirect enum JSONValue: Codable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        if let value = try? container.decode(Int.self) { self = .int(value); return }
        if let value = try? container.decode(Double.self) { self = .double(value); return }
        if let value = try? container.decode(String.self) { self = .string(value); return }
        if let value = try? container.decode([JSONValue].self) { self = .array(value); return }
        if let value = try? container.decode([String: JSONValue].self) { self = .object(value); return }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let v): try container.encode(v)
        case .int(let v): try container.encode(v)
        case .double(let v): try container.encode(v)
        case .string(let v): try container.encode(v)
        case .array(let v): try container.encode(v)
        case .object(let v): try container.encode(v)
        }
    }

    public static func from(_ raw: Any?) -> JSONValue {
        guard let raw else { return .null }
        if raw is NSNull { return .null }
        if let bool = raw as? Bool { return .bool(bool) }
        if let int = raw as? Int { return .int(int) }
        if let double = raw as? Double { return .double(double) }
        if let string = raw as? String { return .string(string) }
        if let array = raw as? [Any] { return .array(array.map(JSONValue.from)) }
        if let dict = raw as? [String: Any] {
            return .object(dict.mapValues(JSONValue.from))
        }
        if let number = raw as? NSNumber {
            // Distinguish int vs double via the underlying type encoding.
            let typeChar = String(cString: number.objCType)
            if typeChar == "c" || typeChar == "B" { return .bool(number.boolValue) }
            if typeChar == "d" || typeChar == "f" { return .double(number.doubleValue) }
            return .int(number.intValue)
        }
        return .null
    }

    public var stringValue: String? {
        if case .string(let v) = self { return v }
        return nil
    }

    public var intValue: Int? {
        switch self {
        case .int(let v): return v
        case .double(let v): return Int(v)
        case .string(let v): return Int(v)
        default: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .double(let v): return v
        case .int(let v): return Double(v)
        case .string(let v): return Double(v)
        default: return nil
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let dict) = self { return dict[key] }
        return nil
    }
}
