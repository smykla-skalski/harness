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

  static let restorationWaitTimeout: Duration = .milliseconds(1500)

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
      let expectedSessionIDs = Set(restorePlan.tabGroupings.flatMap { $0.sessionIDs })
      let registry = SessionWindowAppKitRegistry.shared
      // Edge-triggered: returns as soon as every expected sessionID has an
      // NSWindow bound, falling back to the timeout. Replaces the previous
      // 30 x 50 ms polling loop.
      let converged = await registry.waitForBindings(
        satisfying: { sessionIDs in expectedSessionIDs.isSubset(of: sessionIDs) },
        timeout: Self.restorationWaitTimeout
      )

      let boundSessionIDCount = expectedSessionIDs.reduce(into: 0) { count, sessionID in
        if registry.window(forSessionID: sessionID) != nil {
          count += 1
        }
      }
      let foregroundExpectedCount = restorePlan.tabGroupings.reduce(into: 0) {
        count, grouping in
        if grouping.foregroundSessionID != nil {
          count += 1
        }
      }
      let foregroundResolvedCount = restorePlan.tabGroupings.reduce(into: 0) {
        count, grouping in
        guard let foregroundID = grouping.foregroundSessionID,
          registry.window(forSessionID: foregroundID) != nil
        else {
          return
        }
        count += 1
      }
      HarnessMonitorLogger.lifecycle.info(
        """
        tab-grouping replay groups=\(restorePlan.tabGroupings.count, privacy: .public) \
        expected_members=\(expectedSessionIDs.count, privacy: .public) \
        bound_members=\(boundSessionIDCount, privacy: .public) \
        missed_members=\(expectedSessionIDs.count - boundSessionIDCount, privacy: .public) \
        foreground_resolved=\(foregroundResolvedCount, privacy: .public)/\(foregroundExpectedCount, privacy: .public) \
        converged=\(converged, privacy: .public)
        """
      )

      for grouping in restorePlan.tabGroupings {
        Self.mergeTabGroup(grouping)
      }
    #endif
  }

  private func waitForRestoredSessionWindowsToRegister(sessionIDs: [String]) async {
    let expected = Set(sessionIDs)
    guard !expected.isEmpty else { return }
    #if canImport(AppKit)
      _ = await SessionWindowAppKitRegistry.shared.waitForBindings(
        satisfying: { boundIDs in expected.isSubset(of: boundIDs) },
        timeout: Self.restorationWaitTimeout
      )
    #else
      for _ in 0..<30 {
        if expected.isSubset(of: store.openSessionWindowIDsSnapshot) { return }
        try? await Task.sleep(for: .milliseconds(50))
      }
    #endif
  }

  #if canImport(AppKit)
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
    if hasVisibleSessionWindows() { return true }
    #if canImport(AppKit)
      // SwiftUI window restoration runs asynchronously after launch and on
      // real machines the original 6 x 50 ms (300 ms) polling budget often
      // expired before restored session windows registered, so the router
      // fell through to Welcome and the user saw both. The registry's
      // edge-triggered waiter wakes on the first matching `bind(...)` so
      // warm launches finish on the first event; cold launches stay
      // bounded by the 1.5 s timeout.
      return await SessionWindowAppKitRegistry.shared.waitForBindings(
        satisfying: { boundIDs in !boundIDs.isEmpty },
        timeout: Self.restorationWaitTimeout
      )
    #else
      for _ in 0..<30 {
        try? await Task.sleep(for: .milliseconds(50))
        if hasVisibleSessionWindows() { return true }
      }
      return false
    #endif
  }

  private func hasVisibleSessionWindows() -> Bool {
    !store.openSessionWindowIDsSnapshot.isEmpty
  }
}
