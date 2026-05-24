import Foundation

/// Static scenario catalog shared by the audit CLI, manifest writer, and tests.
public enum ScenarioCatalog {
    public static let all: [String] = PerfScenarioDefinitions.all.map(\.id)

    public static let swiftUI: Set<String> = Set(
        PerfScenarioDefinitions.all
            .filter { $0.templates.contains(.swiftUI) }
            .map(\.id)
    )

    public static let allocations: Set<String> = Set(
        PerfScenarioDefinitions.all
            .filter { $0.templates.contains(.allocations) }
            .map(\.id)
    )

    public static func durationSeconds(for scenario: String) -> Int {
        PerfScenarioDefinitions.byID[scenario]?.durationSeconds ?? 8
    }

    public static func previewScenario(for scenario: String) -> String {
        PerfScenarioDefinitions.byID[scenario]?.defaultPreviewScenario ?? "dashboard"
    }

    public struct Failure: Error, CustomStringConvertible {
        public let message: String
        public var description: String { message }
    }

    public static func resolve(_ selection: String) throws -> [String] {
        if selection == "all" { return all }
        let known = Set(all)
        let parts = selection.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        var out: [String] = []
        for raw in parts where !raw.isEmpty {
            guard known.contains(raw) else {
                throw Failure(message: "unknown scenario: \(raw)")
            }
            out.append(raw)
        }
        if out.isEmpty {
            throw Failure(message: "no scenarios selected")
        }
        return out
    }
}
