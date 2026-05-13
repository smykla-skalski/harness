import Foundation

enum HarnessMonitorUITestPerfScenarioCatalog {
  private static let resourceName = "HarnessMonitorPerfScenarios"
  private static let resourceExtension = "json"

  private static let definitionsByID: [String: Definition] = {
    do {
      return try loadDefinitions()
    } catch {
      preconditionFailure("Failed to load UI perf scenario catalog: \(error)")
    }
  }()

  static let visualOptionsDisabledScenarios: [String] = definitionsByID.values
    .filter(\.disablesVisualOptions)
    .map(\.id)
    .sorted()

  static func expectedPreviewScenario(for scenario: String) -> String {
    definitionsByID[scenario]?.defaultPreviewScenario ?? "dashboard"
  }

  private static func loadDefinitions() throws -> [String: Definition] {
    let candidates = [Bundle(for: BundleToken.self), Bundle.main]
    guard
      let url = candidates.first(where: {
        $0.url(forResource: resourceName, withExtension: resourceExtension) != nil
      })?.url(forResource: resourceName, withExtension: resourceExtension)
    else {
      struct ResourceMissing: Error {}
      throw ResourceMissing()
    }
    let data = try Data(contentsOf: url)
    let source = try JSONDecoder().decode(Source.self, from: data)
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

  private struct Source: Decodable {
    let scenarios: [Definition]
  }

  private struct Definition: Decodable {
    let id: String
    let defaultPreviewScenario: String
    let disablesVisualOptions: Bool
  }
}
