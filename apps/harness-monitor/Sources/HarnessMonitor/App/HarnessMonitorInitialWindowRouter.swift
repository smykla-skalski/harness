import Foundation
import HarnessMonitorUIPreviewable

@MainActor
struct HarnessMonitorInitialWindowRouter {
  let userDefaults: UserDefaults
  let openDashboardWindow: () -> Void

  init(
    userDefaults: UserDefaults = .standard,
    openDashboardWindow: @escaping () -> Void
  ) {
    self.userDefaults = userDefaults
    self.openDashboardWindow = openDashboardWindow
  }

  func route() {
    let plan = HarnessMonitorInitialWindowPlan.resolve(
      dashboardRestoreState: DashboardWindowLifecycleTracker.restoreStateAtQuit(
        userDefaults: userDefaults
      )
    )

    switch plan.destination {
    case .none:
      return
    case .dashboard:
      openDashboardWindow()
    }
  }
}
