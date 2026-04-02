import HarnessKit
import SwiftData

@MainActor
enum HarnessAppStoreFactory {
  private enum PreviewFixtureSet: String {
    case standard
    case overflow

    init(environment: HarnessEnvironment) {
      let rawValue = environment.values["HARNESS_PREVIEW_FIXTURE_SET"]?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
      self = Self(rawValue: rawValue ?? "") ?? .standard
    }
  }

  private enum PreviewScenarioOverride: String {
    case dashboard
    case cockpit
    case offlineCached = "offline-cached"
    case overflow
    case empty

    init?(environment: HarnessEnvironment) {
      let rawValue = environment.values["HARNESS_PREVIEW_SCENARIO"]?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
      guard let rawValue, !rawValue.isEmpty else {
        return nil
      }
      self.init(rawValue: rawValue)
    }

    var scenario: HarnessPreviewStoreFactory.Scenario {
      switch self {
      case .dashboard:
        .dashboardLoaded
      case .cockpit:
        .cockpitLoaded
      case .offlineCached:
        .offlineCached
      case .overflow:
        .sidebarOverflow
      case .empty:
        .empty
      }
    }
  }

  static func makeStore(
    environment: HarnessEnvironment = .current,
    modelContext: ModelContext? = nil,
    persistenceError: String? = nil
  ) -> HarnessStore {
    if let previewScenario = PreviewScenarioOverride(environment: environment) {
      return HarnessPreviewStoreFactory.makeStore(for: previewScenario.scenario)
    }

    let controller: any DaemonControlling

    switch HarnessLaunchMode(environment: environment) {
    case .live:
      controller = DaemonController(environment: environment)
    case .preview:
      controller =
        switch PreviewFixtureSet(environment: environment) {
        case .standard:
          PreviewDaemonController()
        case .overflow:
          PreviewDaemonController(mode: .overflow)
        }
    case .empty:
      controller = PreviewDaemonController(mode: .empty)
    }

    return HarnessStore(
      daemonController: controller,
      modelContext: modelContext,
      persistenceError: persistenceError
    )
  }
}
