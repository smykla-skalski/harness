import HarnessMonitorUIPreviewable

struct HarnessMonitorInitialWindowPlan: Equatable {
  enum Destination: Equatable {
    case none
    case dashboard(mergeIfNeeded: Bool)
  }

  let destination: Destination

  static func resolve(
    launchBehavior: HarnessMonitorLaunchBehavior,
    dashboardRestoreState: Bool?
  ) -> Self {
    switch launchBehavior {
    case .alwaysOpenRecent:
      Self(destination: .dashboard(mergeIfNeeded: true))
    case .restoreSessionWindows:
      switch dashboardRestoreState {
      case true:
        Self(destination: .dashboard(mergeIfNeeded: false))
      case false:
        Self(destination: .none)
      case nil:
        Self(destination: .dashboard(mergeIfNeeded: true))
      }
    }
  }
}
