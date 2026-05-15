import Foundation
import HarnessMonitorUIPreviewable

struct HarnessMonitorPerfScenarioSource: Decodable, Sendable {
  let scenarios: [HarnessMonitorPerfScenarioDefinition]
}

struct HarnessMonitorPerfScenarioDefinition: Decodable, Sendable {
  let id: String
  let signpostName: String
  let defaultPreviewScenario: String
  let initialSettingsSection: String
  let disablesVisualOptions: Bool
  let needsPreviewAcpPermissionBatch: Bool
  let includesBootstrapInMeasurement: Bool
  let usesLiveDaemon: Bool

  private enum CodingKeys: String, CodingKey {
    case id
    case signpostName
    case defaultPreviewScenario
    case initialSettingsSection
    case disablesVisualOptions
    case needsPreviewAcpPermissionBatch
    case includesBootstrapInMeasurement
    case usesLiveDaemon
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
  }
}

enum HarnessMonitorPerfScenarioCatalog {
  private static let resourceName = "HarnessMonitorPerfScenarios"
  private static let resourceExtension = "json"

  static let definitionsByID: [String: HarnessMonitorPerfScenarioDefinition] = {
    do {
      return try loadDefinitions()
    } catch {
      preconditionFailure("Failed to load Harness Monitor perf scenarios: \(error)")
    }
  }()

  static func definition(
    for scenario: HarnessMonitorPerfScenario
  ) -> HarnessMonitorPerfScenarioDefinition {
    guard let definition = definitionsByID[scenario.rawValue] else {
      preconditionFailure("Missing perf scenario definition for \(scenario.rawValue)")
    }
    return definition
  }

  private static func loadDefinitions() throws -> [String: HarnessMonitorPerfScenarioDefinition] {
    let candidates = [Bundle.main, Bundle(for: BundleToken.self)]
    guard
      let url = candidates.first(where: {
        $0.url(forResource: resourceName, withExtension: resourceExtension) != nil
      })?.url(forResource: resourceName, withExtension: resourceExtension)
    else {
      struct ResourceMissing: Error {}
      throw ResourceMissing()
    }
    let data = try Data(contentsOf: url)
    let source = try JSONDecoder().decode(HarnessMonitorPerfScenarioSource.self, from: data)
    let definitions = Dictionary(
      source.scenarios.map { ($0.id, $0) },
      uniquingKeysWith: { existing, _ in existing }
    )
    guard definitions.count == source.scenarios.count else {
      struct DuplicateScenarioIDs: Error {}
      throw DuplicateScenarioIDs()
    }
    return definitions
  }

  private final class BundleToken: NSObject {}
}

extension HarnessMonitorPerfScenarioDefinition {
  var settingsSection: SettingsSection {
    guard let section = SettingsSection(rawValue: initialSettingsSection) else {
      preconditionFailure("Unknown settings section \(initialSettingsSection)")
    }
    return section
  }
}
