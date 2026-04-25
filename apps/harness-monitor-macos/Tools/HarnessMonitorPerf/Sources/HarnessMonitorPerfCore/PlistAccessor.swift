import Foundation

/// Read + upsert helpers backed by `PropertyListSerialization` so the audit pipeline does not
/// shell out to PlistBuddy. Mirrors plist_value / plist_upsert_string / plist_upsert_bool.
public enum PlistAccessor {
    public struct Failure: Error, CustomStringConvertible {
        public let message: String
        public var description: String { message }
    }

    public static func value(at url: URL, key: String) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let object = try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) else { return nil }
        guard let dict = object as? [String: Any] else { return nil }
        if let stringValue = dict[key] as? String { return stringValue }
        if let boolValue = dict[key] as? Bool { return boolValue ? "true" : "false" }
        return nil
    }

    public static func upsertString(at url: URL, key: String, value: String) throws {
        var (dict, format) = try readMutable(url)
        dict[key] = value
        try write(dict, format: format, to: url)
    }

    public static func upsertBool(at url: URL, key: String, value: Bool) throws {
        var (dict, format) = try readMutable(url)
        dict[key] = value
        try write(dict, format: format, to: url)
    }

    private static func readMutable(_ url: URL) throws -> ([String: Any], PropertyListSerialization.PropertyListFormat) {
        let data = try Data(contentsOf: url)
        var format: PropertyListSerialization.PropertyListFormat = .xml
        guard let object = try PropertyListSerialization.propertyList(
            from: data, options: [], format: &format
        ) as? [String: Any] else {
            throw Failure(message: "plist root is not a dict: \(url.path)")
        }
        return (object, format)
    }

    private static func write(
        _ dict: [String: Any],
        format: PropertyListSerialization.PropertyListFormat,
        to url: URL
    ) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: format, options: 0)
        try data.write(to: url, options: .atomic)
    }
}
