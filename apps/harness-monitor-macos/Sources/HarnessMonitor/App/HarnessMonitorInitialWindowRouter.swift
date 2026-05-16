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

  // Upper bound for SwiftUI's `WindowGroup(id:for:)` restoration to bind
  // every restored session window. 1.5 s was sized against Apple Silicon
  // hardware with cold disk caches and FileVault on during development of
  // 903a0eec0; the prior 6 x 50 ms (300 ms) budget regularly expired before
  // restored windows registered. The real-world distribution has not yet
  // been measured at scale — operators tracking the `lifecycle` log can
  // collect the `converged` field per launch from the breadcrumbs emitted
  // in `replayTabGroupingsIfNeeded`, `waitForRestoredSessionWindowsToRegister`,
  // and `waitForVisibleSessionWindowDuringLaunch`. If `converged=false`
  // shows up at non-trivial rates, prefer collapsing the two registries
  // (or finding a SwiftUI restoration-complete signal) over raising this
  // number further.
  static let restorationWaitTimeout: Duration = .milliseconds(1500)

  func route() async {
    let shouldRestoreDashboard =
      launchBehavior == .restoreSessionWindows
      && DashboardWindowLifecycleTracker.wasOpenAtQuit()
    let restorePlan = await prepareRestorePlan()

    if await restoreVisibleWindowsIfNeeded(
      shouldRestoreDashboard: shouldRestoreDashboard,
      restorePlan: restorePlan
    ) {
      return
    }
    if await restoreAutoRestoredWindowsIfNeeded(
      shouldRestoreDashboard: shouldRestoreDashboard,
      restorePlan: restorePlan
    ) {
      return
    }
    await routeInitialPlan(
      shouldRestoreDashboard: shouldRestoreDashboard,
      restorePlan: restorePlan
    )
  }

  private func prepareRestorePlan() async -> HarnessMonitorStore.LaunchWindowRestorePlan {
    guard launchBehavior == .restoreSessionWindows else {
      return HarnessMonitorStore.LaunchWindowRestorePlan()
    }
    await store.prepareOpenRecentSessions()
    return await store.launchWindowRestorePlan()
  }

  private func restoreVisibleWindowsIfNeeded(
    shouldRestoreDashboard: Bool,
    restorePlan: HarnessMonitorStore.LaunchWindowRestorePlan
  ) async -> Bool {
    guard launchBehavior == .restoreSessionWindows, hasVisibleSessionWindows() else {
      return false
    }
    if shouldRestoreDashboard {
      openWelcomeWindow()
    }
    await replayTabGroupingsIfNeeded(in: restorePlan)
    return true
  }

  private func restoreAutoRestoredWindowsIfNeeded(
    shouldRestoreDashboard: Bool,
    restorePlan: HarnessMonitorStore.LaunchWindowRestorePlan
  ) async -> Bool {
    guard launchBehavior == .restoreSessionWindows, !restorePlan.sessionIDs.isEmpty else {
      return false
    }
    guard await waitForVisibleSessionWindowDuringLaunch() else {
      return false
    }
    if shouldRestoreDashboard {
      openWelcomeWindow()
    }
    await replayTabGroupingsIfNeeded(in: restorePlan)
    return true
  }

  private func routeInitialPlan(
    shouldRestoreDashboard: Bool,
    restorePlan: HarnessMonitorStore.LaunchWindowRestorePlan
  ) async {
    let initialPlan = HarnessMonitorInitialWindowPlan.resolve(
      launchBehavior: launchBehavior,
      hasVisibleSessionWindows: hasVisibleSessionWindows(),
      restorePlan: restorePlan
    )

    switch initialPlan.destination {
    case .none:
      if shouldRestoreDashboard {
        openWelcomeWindow()
      }
    case .welcome:
      openWelcomeWindow()
    case .sessions(let sessionIDs):
      if shouldRestoreDashboard {
        openWelcomeWindow()
      }
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
      let toolbarsReady = await waitForSessionWindowToolbars(
        sessionIDs: expectedSessionIDs,
        registry: registry
      )

      let boundSessionIDCount = expectedSessionIDs.reduce(into: 0) { count, sessionID in
        if registry.window(forSessionID: sessionID) != nil {
          count += 1
        }
      }
      let foregroundExpectedCount = restorePlan.tabGroupings.reduce(into: 0) { count, grouping in
        if grouping.foregroundSessionID != nil {
          count += 1
        }
      }
      let foregroundResolvedCount = restorePlan.tabGroupings.reduce(into: 0) { count, grouping in
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
        toolbars_ready=\(toolbarsReady, privacy: .public) \
        foreground_resolved=\(foregroundResolvedCount, privacy: .public)/\
        \(foregroundExpectedCount, privacy: .public) \
        converged=\(converged, privacy: .public)
        """
      )

      for grouping in restorePlan.tabGroupings {
        Self.mergeTabGroup(grouping)
      }
    #endif
  }

  #if canImport(AppKit)
    private func waitForSessionWindowToolbars(
      sessionIDs: Set<String>,
      registry: SessionWindowAppKitRegistry
    ) async -> Bool {
      guard !sessionIDs.isEmpty else {
        return true
      }

      let deadline = ContinuousClock.now + Self.restorationWaitTimeout
      while ContinuousClock.now < deadline {
        let allToolbarsReady = sessionIDs.allSatisfy { sessionID in
          registry.window(forSessionID: sessionID)?.toolbar != nil
        }
        if allToolbarsReady {
          return true
        }
        try? await Task.sleep(for: .milliseconds(50))
      }

      return sessionIDs.allSatisfy { sessionID in
        registry.window(forSessionID: sessionID)?.toolbar != nil
      }
    }
  #endif

  private func waitForRestoredSessionWindowsToRegister(sessionIDs: [String]) async {
    let expected = Set(sessionIDs)
    guard !expected.isEmpty else { return }
    #if canImport(AppKit)
      let start = Date.now
      let converged = await SessionWindowAppKitRegistry.shared.waitForBindings(
        satisfying: { boundIDs in expected.isSubset(of: boundIDs) },
        timeout: Self.restorationWaitTimeout
      )
      HarnessMonitorLogger.lifecycle.info(
        """
        session-window bridge-fallback wait \
        expected=\(expected.count, privacy: .public) \
        converged=\(converged, privacy: .public) \
        elapsed_ms=\(Int(Date.now.timeIntervalSince(start) * 1000), privacy: .public)
        """
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
      let tabReadyWindows = windows.filter { $0.toolbar != nil }
      guard let anchor = tabReadyWindows.first, tabReadyWindows.count > 1 else { return }
      for next in tabReadyWindows.dropFirst() {
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
      // bounded by the timeout. Emit a breadcrumb so operators can build
      // a real distribution of cold-launch convergence times — see the
      // `restorationWaitTimeout` doc-comment for why that distribution
      // matters.
      let start = Date.now
      let converged = await SessionWindowAppKitRegistry.shared.waitForBindings(
        satisfying: { boundIDs in !boundIDs.isEmpty },
        timeout: Self.restorationWaitTimeout
      )
      HarnessMonitorLogger.lifecycle.info(
        """
        session-window cold-launch wait \
        converged=\(converged, privacy: .public) \
        elapsed_ms=\(Int(Date.now.timeIntervalSince(start) * 1000), privacy: .public)
        """
      )
      return converged
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
