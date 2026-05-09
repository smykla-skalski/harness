import HarnessMonitorKit
import HarnessMonitorUIPreviewable

@MainActor
struct HarnessMonitorInitialWindowRouter {
  let store: HarnessMonitorStore
  let launchBehavior: HarnessMonitorLaunchBehavior
  let openWelcomeWindow: () -> Void
  let openSessionWindow: (String) -> Void

  func route() async {
    let restoredSessionWindowVisible = await waitForVisibleSessionWindowDuringLaunch()
    if launchBehavior == .restoreSessionWindows, restoredSessionWindowVisible {
      return
    }

    var restorePlan = HarnessMonitorStore.LaunchWindowRestorePlan()
    if launchBehavior == .restoreSessionWindows {
      await store.prepareOpenRecentSessions()
      if hasVisibleSessionWindows() {
        return
      }
      restorePlan = await store.launchWindowRestorePlan()
    }

    let initialPlan = HarnessMonitorInitialWindowPlan.resolve(
      launchBehavior: launchBehavior,
      hasVisibleSessionWindows: hasVisibleSessionWindows(),
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

  private func waitForVisibleSessionWindowDuringLaunch() async -> Bool {
    guard !hasVisibleSessionWindows() else {
      return true
    }
    for _ in 0..<6 {
      try? await Task.sleep(for: .milliseconds(50))
      guard !hasVisibleSessionWindows() else {
        return true
      }
    }
    return hasVisibleSessionWindows()
  }

  private func hasVisibleSessionWindows() -> Bool {
    !store.openSessionWindowIDsSnapshot.isEmpty
  }
}
