import HarnessMonitorKit
import HarnessMonitorUIPreviewable

#if canImport(AppKit)
  import AppKit
#endif

@MainActor
struct HarnessMonitorInitialWindowRouter {
  let store: HarnessMonitorStore
  let launchBehavior: HarnessMonitorLaunchBehavior
  let tabbingPreference: SessionWindowTabbingPreference
  let openWelcomeWindow: () -> Void
  let openSessionWindow: (String) -> Void

  func route() async {
    var restorePlan = HarnessMonitorStore.LaunchWindowRestorePlan()
    if launchBehavior == .restoreSessionWindows {
      await store.prepareOpenRecentSessions()
      if hasVisibleSessionWindows() {
        await replayTabGroupingsIfNeeded(in: restorePlan)
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
        await replayTabGroupingsIfNeeded(in: restorePlan)
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
      await waitForRestoredSessionWindowsToRegister(sessionIDs: sessionIDs)
      await replayTabGroupingsIfNeeded(in: restorePlan)
    }

    if initialPlan.shouldMarkBridgeFallbackComplete {
      store.completeLaunchWindowBridgeFallback()
    }
  }

  private func replayTabGroupingsIfNeeded(
    in restorePlan: HarnessMonitorStore.LaunchWindowRestorePlan
  ) async {
    guard tabbingPreference != .never else { return }
    guard !restorePlan.tabGroupings.isEmpty else { return }
    #if canImport(AppKit)
      // Bindings update on MainActor when each restored session window's
      // SessionWindowAppKitBinding view moves into its NSWindow. The
      // store-side openSessionWindowIDsSnapshot may briefly populate
      // before the AppKit registry catches up with that scene mount, so
      // give the registry a small budget to converge before merging.
      for _ in 0..<30 {
        if HarnessMonitorInitialWindowRouter.allWindowsBoundForGroupings(
          restorePlan.tabGroupings
        ) {
          break
        }
        try? await Task.sleep(for: .milliseconds(50))
      }
      for grouping in restorePlan.tabGroupings {
        Self.mergeTabGroup(grouping)
      }
    #endif
  }

  private func waitForRestoredSessionWindowsToRegister(sessionIDs: [String]) async {
    let expected = Set(sessionIDs)
    for _ in 0..<30 {
      if expected.isSubset(of: store.openSessionWindowIDsSnapshot) {
        return
      }
      try? await Task.sleep(for: .milliseconds(50))
    }
  }

  #if canImport(AppKit)
    private static func allWindowsBoundForGroupings(
      _ groupings: [HarnessMonitorStore.SessionTabGroupSnapshot]
    ) -> Bool {
      let registry = SessionWindowAppKitRegistry.shared
      for grouping in groupings {
        for sessionID in grouping.sessionIDs {
          if registry.window(forSessionID: sessionID) == nil {
            return false
          }
        }
      }
      return true
    }

    private static func mergeTabGroup(
      _ grouping: HarnessMonitorStore.SessionTabGroupSnapshot
    ) {
      let registry = SessionWindowAppKitRegistry.shared
      let windows = grouping.sessionIDs.compactMap { sessionID in
        registry.window(forSessionID: sessionID)
      }
      guard let anchor = windows.first, windows.count > 1 else { return }
      for next in windows.dropFirst() {
        guard next !== anchor else { continue }
        // Skip if AppKit already merged them (matching tabbingIdentifier
        // + user pref Always reaches us with a tab group already formed).
        if let group = anchor.tabGroup, group === next.tabGroup {
          continue
        }
        anchor.addTabbedWindow(next, ordered: .above)
      }
      if let foregroundID = grouping.foregroundSessionID,
        let foregroundWindow = registry.window(forSessionID: foregroundID),
        let tabGroup = foregroundWindow.tabGroup
      {
        tabGroup.selectedWindow = foregroundWindow
      }
    }
  #endif

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
