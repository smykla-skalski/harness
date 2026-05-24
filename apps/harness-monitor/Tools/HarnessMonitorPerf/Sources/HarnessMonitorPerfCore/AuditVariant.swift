import Foundation

public struct AuditVariant: Codable, Equatable, Sendable {
    public static let defaultSelection = [
        "baseline",
        "no-search-host",
        "no-search-suggestions",
        "scene-writes-enabled",
        "static-detail",
    ].joined(separator: ",")

    public var id: String
    public var environment: [String: String]

    public init(id: String, environment: [String: String]) {
        self.id = id
        self.environment = environment
    }

    public static func resolve(_ selection: String?) throws -> [AuditVariant] {
        let rawSelection = selection?.trimmingCharacters(in: .whitespacesAndNewlines)
        let selected = rawSelection?.isEmpty == false ? rawSelection! : defaultSelection
        var variants: [AuditVariant] = []
        for part in selected.split(separator: ",") {
            let id = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { continue }
            guard let variant = byID[id] else {
                throw Failure(message: "unknown audit variant: \(id)")
            }
            variants.append(variant)
        }
        guard !variants.isEmpty else {
            throw Failure(message: "no audit variants selected")
        }
        return variants
    }

    public struct Failure: Error, CustomStringConvertible {
        public let message: String
        public var description: String { message }
    }

    private static let byID: [String: AuditVariant] = [
        "baseline": AuditVariant(id: "baseline", environment: [:]),
        "no-search-host": AuditVariant(
            id: "no-search-host",
            environment: ["HARNESS_MONITOR_PERF_DISABLE_SEARCH_HOST": "1"]
        ),
        "no-search-suggestions": AuditVariant(
            id: "no-search-suggestions",
            environment: ["HARNESS_MONITOR_PERF_DISABLE_SEARCH_SUGGESTIONS": "1"]
        ),
        "scene-writes-enabled": AuditVariant(
            id: "scene-writes-enabled",
            environment: ["HARNESS_MONITOR_PERF_ENABLE_SCENE_WRITES": "1"]
        ),
        "static-detail": AuditVariant(
            id: "static-detail",
            environment: ["HARNESS_MONITOR_PERF_STATIC_DETAIL": "1"]
        ),
    ]
}
