import HarnessMonitorKit
import HarnessMonitorUIPreviewable
import SwiftUI

extension HarnessMonitorApp {
  var shouldHandleInitialWindowRouting: Bool {
    launchMode == .live && !isTestRun
  }

  func installMainWindowLauncherIfNeeded() {
    guard !hasInstalledMainWindowLauncherFlag else {
      return
    }
    hasInstalledMainWindowLauncherFlag = true
    HarnessMonitorMainWindowLauncher.shared.installOpenMainWindow {
      openWindow.openHarnessDashboardWindow()
    }
  }

  func scheduleInitialWindowRoutingIfNeeded() {
    guard shouldHandleInitialWindowRouting else {
      return
    }
    guard !hasScheduledInitialWindowRoutingFlag else {
      return
    }
    // Live launches set `defaultLaunchBehavior(.suppressed)` on every scene,
    // so no window opens automatically and the App-level scenePhase never
    // advances past `.background`. Routing therefore fires on the first
    // scenePhase callback regardless of its value:
    // `installMainWindowLauncherIfNeeded` runs in the same closure first so
    // the launcher's `openWindow` closure is already captured, and the
    // routed Task runs on MainActor where `openWindow` is valid.
    hasScheduledInitialWindowRoutingFlag = true
    Task { @MainActor in
      await routeInitialWindows()
    }
  }

  @MainActor
  func routeInitialWindows() async {
    let router = HarnessMonitorInitialWindowRouter(
      openDashboardWindow: {
        openWindow.openHarnessDashboardWindow()
      }
    )
    router.route()
  }
}
