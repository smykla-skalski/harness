import AppKit
import HarnessMonitorKit
import HarnessMonitorUIPreviewable

@MainActor
struct HarnessMonitorInitialWindowRouter {
  let store: HarnessMonitorStore
  let launchBehavior: HarnessMonitorLaunchBehavior
  let openWelcomeWindow: () -> Void
  let openSessionWindow: (String) -> Void

  func route() async {
    let restoredWindowVisible = await waitForVisibleHarnessWindowDuringLaunch()
    if restoredWindowVisible {
      return
    }

    var restorePlan = HarnessMonitorStore.LaunchWindowRestorePlan()
    if launchBehavior == .restoreSessionWindows {
      await store.prepareOpenRecentSessions()
      if hasVisibleHarnessWindow() {
        return
      }
      restorePlan = await store.launchWindowRestorePlan()
    }

    let initialPlan = HarnessMonitorInitialWindowPlan.resolve(
      launchBehavior: launchBehavior,
      hasVisibleWindows: hasVisibleHarnessWindow(),
      restorePlan: restorePlan
    )

    switch initialPlan.destination {
    case .none:
      break
    case .welcome:
      openWelcomeWindow()
    case .sessions(let sessionIDs):
      for sessionID in sessionIDs {
        openSessionWindow(sessionID)
      }
    }

    if initialPlan.shouldMarkBridgeFallbackComplete {
      store.completeLaunchWindowBridgeFallback()
    }
  }

  private func waitForVisibleHarnessWindowDuringLaunch() async -> Bool {
    guard !hasVisibleHarnessWindow() else {
      return true
    }
    for _ in 0..<6 {
      try? await Task.sleep(for: .milliseconds(50))
      guard !hasVisibleHarnessWindow() else {
        return true
      }
    }
    return hasVisibleHarnessWindow()
  }

  private func hasVisibleHarnessWindow() -> Bool {
    NSApplication.shared.windows.contains { window in
      window.isVisible && !window.isMiniaturized
    }
  }
}
