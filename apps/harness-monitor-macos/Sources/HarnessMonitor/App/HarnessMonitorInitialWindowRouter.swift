import HarnessMonitorKit
import HarnessMonitorUIPreviewable

@MainActor
struct HarnessMonitorInitialWindowRouter {
  let store: HarnessMonitorStore
  let launchBehavior: HarnessMonitorLaunchBehavior
  let openWelcomeWindow: () -> Void
  let openSessionWindow: (String) -> Void

  func route() async {
    var restorePlan = HarnessMonitorStore.LaunchWindowRestorePlan()
    if launchBehavior == .restoreSessionWindows {
      await store.prepareOpenRecentSessions()
      if hasVisibleSessionWindows() {
        return
      }
      restorePlan = await store.launchWindowRestorePlan()
    }

    // Only wait for SwiftUI auto-restoration when there is something the
    // system might restore. Fresh users with an empty plan skip the wait
    // and reach Welcome immediately; users with a non-empty plan let
    // SwiftUI win so the briefly-stacked Open Recent + sessions overlap
    // does not appear.
    if launchBehavior == .restoreSessionWindows, !restorePlan.sessionIDs.isEmpty {
      if await waitForVisibleSessionWindowDuringLaunch() {
        return
      }
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
    // SwiftUI window restoration runs asynchronously after launch and on
    // real machines the original 6 x 50 ms (300 ms) budget expired before
    // restored session windows registered, so the router fell through to
    // Welcome and the user saw both. 30 x 50 ms (1.5 s) consistently
    // wins, with an early-out on the first registration so warm launches
    // are not penalised.
    for _ in 0..<30 {
      try? await Task.sleep(for: .milliseconds(50))
      if hasVisibleSessionWindows() {
        return true
      }
    }
    return hasVisibleSessionWindows()
  }

  private func hasVisibleSessionWindows() -> Bool {
    !store.openSessionWindowIDsSnapshot.isEmpty
  }
}
