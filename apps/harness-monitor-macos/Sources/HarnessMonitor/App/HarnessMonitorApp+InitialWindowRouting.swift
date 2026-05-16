import HarnessMonitorKit
import HarnessMonitorUIPreviewable
import SwiftUI

extension HarnessMonitorApp {
  var launchBehavior: HarnessMonitorLaunchBehavior {
    HarnessMonitorLaunchBehavior.resolved(rawValue: sessionWindowLaunchModeRawValue)
  }

  var shouldHandleInitialWindowRouting: Bool {
    (launchMode == .live && !isTestRun) || initialSessionWindowRoute != nil
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
    if let initialSessionWindowRoute {
      let sessionID = appStore.selectedSessionID ?? appStore.sessions.first?.sessionId
      HarnessMonitorUITestTrace.record(
        component: "app.startup",
        event: "preview-session-route",
        details: [
          "route": initialSessionWindowRoute.rawValue,
          "has_session": String(sessionID != nil),
        ]
      )
      openWindow.openHarnessSessionWindow(sessionID: sessionID)
      return
    }

    let tabbingPreference = SessionWindowTabbingPreference.resolved(
      rawValue: UserDefaults.standard.string(forKey: SessionWindowTabbingPreference.storageKey)
    )
    let router = HarnessMonitorInitialWindowRouter(
      store: appStore,
      launchBehavior: launchBehavior,
      tabbingPreference: tabbingPreference,
      openWelcomeWindow: { mergeIfNeeded in
        openWindow.openHarnessDashboardWindow(mergeIfNeeded: mergeIfNeeded)
      },
      openSessionWindow: { sessionID, mergeIfNeeded in
        openWindow.openHarnessSessionWindow(
          sessionID: sessionID,
          mergeIfNeeded: mergeIfNeeded
        )
      }
    )
    await router.route()
  }
}
