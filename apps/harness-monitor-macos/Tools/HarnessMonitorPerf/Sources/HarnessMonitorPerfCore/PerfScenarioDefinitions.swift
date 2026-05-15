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
    let usesLiveDaemon: Bool
    let durationSeconds: Int
    let launchBudgetMilliseconds: Double?
    let templates: [PerfScenarioTemplate]
    let swiftUIBudget: Budgets.SwiftUIBudget?
    let allocationsBudget: Budgets.AllocationsBudget?

    private enum CodingKeys: String, CodingKey {
        case id
        case signpostName
        case defaultPreviewScenario
        case initialSettingsSection
        case disablesVisualOptions
        case needsPreviewAcpPermissionBatch
        case includesBootstrapInMeasurement
        case usesLiveDaemon
        case durationSeconds
        case launchBudgetMilliseconds
        case templates
        case swiftUIBudget
        case allocationsBudget
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        signpostName = try container.decode(String.self, forKey: .signpostName)
        defaultPreviewScenario = try container.decode(String.self, forKey: .defaultPreviewScenario)
        initialSettingsSection = try container.decode(String.self, forKey: .initialSettingsSection)
        disablesVisualOptions = try container.decode(Bool.self, forKey: .disablesVisualOptions)
        needsPreviewAcpPermissionBatch = try container.decode(
            Bool.self,
            forKey: .needsPreviewAcpPermissionBatch
        )
        includesBootstrapInMeasurement = try container.decode(
            Bool.self,
            forKey: .includesBootstrapInMeasurement
        )
        usesLiveDaemon = try container.decodeIfPresent(Bool.self, forKey: .usesLiveDaemon) ?? false
        durationSeconds = try container.decode(Int.self, forKey: .durationSeconds)
        launchBudgetMilliseconds = try container.decodeIfPresent(
            Double.self,
            forKey: .launchBudgetMilliseconds
        )
        templates = try container.decode([PerfScenarioTemplate].self, forKey: .templates)
        swiftUIBudget = try container.decodeIfPresent(
            Budgets.SwiftUIBudget.self,
            forKey: .swiftUIBudget
        )
        allocationsBudget = try container.decodeIfPresent(
            Budgets.AllocationsBudget.self,
            forKey: .allocationsBudget
        )
    }
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
