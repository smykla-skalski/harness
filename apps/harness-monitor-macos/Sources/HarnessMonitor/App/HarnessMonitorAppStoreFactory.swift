import HarnessMonitorKit
import SwiftData

@MainActor
enum HarnessMonitorAppStoreFactory {
  private enum PreviewScenarioOverride: String {
    case dashboardLanding = "dashboard-landing"
    case dashboard
    case cockpit
    case offlineCached = "offline-cached"
    case overflow
    case empty

    init?(environment: HarnessMonitorEnvironment) {
      let rawValue = environment.values["HARNESS_MONITOR_PREVIEW_SCENARIO"]?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
      guard let rawValue, !rawValue.isEmpty else {
        return nil
      }
      self.init(rawValue: rawValue)
    }

    var scenario: HarnessMonitorPreviewStoreFactory.Scenario {
      switch self {
      case .dashboardLanding:
        .dashboardLanding
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
    environment: HarnessMonitorEnvironment = .current,
    modelContainer: ModelContainer? = nil,
    persistenceError: String? = nil
  ) -> HarnessMonitorStore {
    if let previewScenario = PreviewScenarioOverride(environment: environment) {
      return HarnessMonitorPreviewStoreFactory.makeStore(
        for: previewScenario.scenario,
        modelContainer: modelContainer,
        persistenceError: persistenceError
      )
    }

    let controller: any DaemonControlling

    switch HarnessMonitorLaunchMode(environment: environment) {
    case .live:
      controller = DaemonController(environment: environment)
    case .preview:
      controller = PreviewDaemonController(
        previewFixtureSetRawValue: environment.values["HARNESS_MONITOR_PREVIEW_FIXTURE_SET"]
      )
    case .empty:
      controller = PreviewDaemonController(mode: .empty)
    }

    return HarnessMonitorStore(
      daemonController: controller,
      modelContainer: modelContainer,
      persistenceError: persistenceError
    )
  }
}
