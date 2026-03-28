import HarnessMonitorKit

@MainActor
enum HarnessMonitorAppStoreFactory {
  static func makeStore(environment: MonitorEnvironment = .current) -> MonitorStore {
    let controller: any DaemonControlling

    switch MonitorLaunchMode(environment: environment) {
    case .live:
      controller = DaemonController(environment: environment)
    case .preview:
      controller = PreviewDaemonController()
    case .empty:
      controller = PreviewDaemonController(mode: .empty)
    }

    return MonitorStore(daemonController: controller)
  }
}
