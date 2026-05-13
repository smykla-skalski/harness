import Foundation

enum PerfScenarioTemplate: String, Codable, Sendable {
    case swiftUI = "swiftui"
    case allocations
}

struct PerfScenarioDefinitionSource: Decodable, Sendable {
    let scenarios: [PerfScenarioDefinition]
}

struct PerfScenarioDefinition: Decodable, Sendable, Equatable {
    let id: String
    let signpostName: String
    let defaultPreviewScenario: String
    let initialSettingsSection: String
    let disablesVisualOptions: Bool
    let needsPreviewAcpPermissionBatch: Bool
    let includesBootstrapInMeasurement: Bool
    let durationSeconds: Int
    let launchBudgetMilliseconds: Double?
    let templates: [PerfScenarioTemplate]
    let swiftUIBudget: Budgets.SwiftUIBudget?
    let allocationsBudget: Budgets.AllocationsBudget?
}

enum PerfScenarioDefinitions {
    private static let environmentKey = "HARNESS_MONITOR_PERF_SCENARIO_CATALOG_PATH"
    private static let resourceName = "HarnessMonitorPerfScenarios.json"

    static let all: [PerfScenarioDefinition] = {
        do {
            return try load()
        } catch {
            preconditionFailure("Failed to load perf scenario definitions: \(error)")
        }
    }()

    static let byID: [String: PerfScenarioDefinition] = Dictionary(
        all.map { ($0.id, $0) },
        uniquingKeysWith: { existing, _ in existing }
    )

    private static func load() throws -> [PerfScenarioDefinition] {
        let data = try Data(contentsOf: catalogURL())
        let source = try JSONDecoder().decode(PerfScenarioDefinitionSource.self, from: data)
        guard byUniqueID(source.scenarios).count == source.scenarios.count else {
            struct DuplicateScenarioIDs: Error {}
            throw DuplicateScenarioIDs()
        }
        return source.scenarios
    }

    private static func byUniqueID(_ definitions: [PerfScenarioDefinition]) -> [String: PerfScenarioDefinition] {
        Dictionary(definitions.map { ($0.id, $0) }, uniquingKeysWith: { existing, _ in existing })
    }

    private static func catalogURL() -> URL {
        if let override = ProcessInfo.processInfo.environment[environmentKey],
            !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return URL(fileURLWithPath: override)
        }

        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent(resourceName)
    }
}
