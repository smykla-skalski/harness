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

  static func makeStore(
    environment: HarnessEnvironment = .current,
    modelContext: ModelContext? = nil,
    persistenceError: String? = nil
  ) -> HarnessStore {
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
