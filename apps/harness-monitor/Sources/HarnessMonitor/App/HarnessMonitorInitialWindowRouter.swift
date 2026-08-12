import Foundation
import HarnessMonitorUIPreviewable

@MainActor
struct HarnessMonitorInitialWindowRouter {
  let userDefaults: UserDefaults
  let prepareToPresentApplicationWindow: () -> Void
  let openDashboardWindow: () -> Void
  let activateApplication: () -> Void

  init(
    userDefaults: UserDefaults = .standard,
    prepareToPresentApplicationWindow: @escaping () -> Void,
    openDashboardWindow: @escaping () -> Void,
    activateApplication: @escaping () -> Void
  ) {
    self.userDefaults = userDefaults
    self.prepareToPresentApplicationWindow = prepareToPresentApplicationWindow
    self.openDashboardWindow = openDashboardWindow
    self.activateApplication = activateApplication
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
      prepareToPresentApplicationWindow()
      openDashboardWindow()
      activateApplication()
    }
  }
}
