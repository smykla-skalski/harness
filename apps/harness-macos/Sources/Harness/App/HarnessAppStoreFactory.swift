import HarnessKit
import SwiftData

@MainActor
enum HarnessAppStoreFactory {
  static func makeStore(
    environment: HarnessEnvironment = .current,
    modelContext: ModelContext? = nil
  ) -> HarnessStore {
    let controller: any DaemonControlling

    switch HarnessLaunchMode(environment: environment) {
    case .live:
      controller = DaemonController(environment: environment)
    case .preview:
      controller = PreviewDaemonController()
    case .empty:
      controller = PreviewDaemonController(mode: .empty)
    }

    return HarnessStore(daemonController: controller, modelContext: modelContext)
  }
}
