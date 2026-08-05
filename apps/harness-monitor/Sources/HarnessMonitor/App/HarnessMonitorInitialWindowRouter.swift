import Foundation
import HarnessMonitorUIPreviewable

@MainActor
struct HarnessMonitorInitialWindowRouter {
  let launchBehavior: HarnessMonitorLaunchBehavior
  let userDefaults: UserDefaults
  let openDashboardWindow: (Bool) -> Void

  init(
    launchBehavior: HarnessMonitorLaunchBehavior,
    userDefaults: UserDefaults = .standard,
    openDashboardWindow: @escaping (Bool) -> Void
  ) {
    self.launchBehavior = launchBehavior
    self.userDefaults = userDefaults
    self.openDashboardWindow = openDashboardWindow
  }

  func route() {
    let plan = HarnessMonitorInitialWindowPlan.resolve(
      launchBehavior: launchBehavior,
      dashboardRestoreState: DashboardWindowLifecycleTracker.restoreStateAtQuit(
        userDefaults: userDefaults
      )
    )

    switch plan.destination {
    case .none:
      return
    case .dashboard(let mergeIfNeeded):
      openDashboardWindow(mergeIfNeeded)
    }
  }
}
