import HarnessKit

@MainActor
enum HarnessAppStoreFactory {
  static func makeStore(environment: HarnessEnvironment = .current) -> HarnessStore {
    let controller: any DaemonControlling

    switch HarnessLaunchMode(environment: environment) {
    case .live:
      controller = DaemonController(environment: environment)
    case .preview:
      controller = PreviewDaemonController()
    case .empty:
      controller = PreviewDaemonController(mode: .empty)
    }

    return HarnessStore(daemonController: controller)
  }
}
