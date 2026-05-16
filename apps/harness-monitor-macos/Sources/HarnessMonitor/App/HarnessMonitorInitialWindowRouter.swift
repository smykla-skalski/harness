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
      let replayOutcome = await SessionWindowTabGroupReplayer.replay(
        restorePlan.tabGroupings,
        registry: registry,
        timeout: Self.restorationWaitTimeout
      )

      let foregroundExpectedCount = restorePlan.tabGroupings.reduce(into: 0) { count, grouping in
        if grouping.foregroundSessionID != nil {
          count += 1
        }
      }
      HarnessMonitorLogger.lifecycle.info(
        """
        tab-grouping replay groups=\(restorePlan.tabGroupings.count, privacy: .public) \
        expected_members=\(expectedSessionIDs.count, privacy: .public) \
        bound_members=\(replayOutcome.boundSessionIDCount, privacy: .public) \
        missed_members=\(expectedSessionIDs.count - replayOutcome.boundSessionIDCount, privacy: .public) \
        toolbars_ready=\(replayOutcome.toolbarsReady, privacy: .public) \
        tab_ready_members=\(replayOutcome.tabReadySessionIDCount, privacy: .public) \
        groups_resolved=\(replayOutcome.resolvedGroupCount, privacy: .public)/\
        \(restorePlan.tabGroupings.count, privacy: .public) \
        foreground_resolved=\(replayOutcome.foregroundResolvedCount, privacy: .public)/\
        \(foregroundExpectedCount, privacy: .public) \
        attempts=\(replayOutcome.attempts, privacy: .public) \
        converged=\(converged, privacy: .public)
        """
      )
    #endif
  }

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

#if canImport(AppKit)
  @MainActor
  enum SessionWindowTabGroupReplayer {
    struct ReplayOutcome: Equatable {
      let attempts: Int
      let boundSessionIDCount: Int
      let tabReadySessionIDCount: Int
      let toolbarsReady: Bool
      let resolvedGroupCount: Int
      let foregroundResolvedCount: Int
    }

    struct MergeOutcome: Equatable {
      let resolved: Bool
      let foregroundResolved: Bool
      let missingTabReadySessionIDs: [String]
    }

    static func replay(
      _ groupings: [HarnessMonitorStore.SessionTabGroupSnapshot],
      registry: SessionWindowAppKitRegistry = .shared,
      timeout: Duration,
      pollInterval: Duration = .milliseconds(50)
    ) async -> ReplayOutcome {
      let expectedSessionIDs = Set(groupings.flatMap { $0.sessionIDs })
      guard !expectedSessionIDs.isEmpty else {
        return ReplayOutcome(
          attempts: 0,
          boundSessionIDCount: 0,
          tabReadySessionIDCount: 0,
          toolbarsReady: true,
          resolvedGroupCount: 0,
          foregroundResolvedCount: 0
        )
      }

      let deadline = ContinuousClock.now + timeout
      var attempts = 0

      while true {
        attempts += 1

        let boundSessionIDCount = expectedSessionIDs.reduce(into: 0) { count, sessionID in
          if registry.window(forSessionID: sessionID) != nil {
            count += 1
          }
        }
        let toolbarsReady = expectedSessionIDs.allSatisfy { sessionID in
          registry.window(forSessionID: sessionID)?.toolbar != nil
        }
        let tabReadySessionIDCount = expectedSessionIDs.reduce(into: 0) { count, sessionID in
          guard let window = registry.window(forSessionID: sessionID), isWindowTabReady(window) else {
            return
          }
          count += 1
        }

        var resolvedGroupCount = 0
        var foregroundResolvedCount = 0
        for grouping in groupings {
          let mergeOutcome = attemptMerge(grouping, registry: registry)
          if mergeOutcome.resolved {
            resolvedGroupCount += 1
          }
          if mergeOutcome.foregroundResolved {
            foregroundResolvedCount += 1
          }
        }

        let replayOutcome = ReplayOutcome(
          attempts: attempts,
          boundSessionIDCount: boundSessionIDCount,
          tabReadySessionIDCount: tabReadySessionIDCount,
          toolbarsReady: toolbarsReady,
          resolvedGroupCount: resolvedGroupCount,
          foregroundResolvedCount: foregroundResolvedCount
        )
        if resolvedGroupCount == groupings.count || ContinuousClock.now >= deadline {
          return replayOutcome
        }

        try? await Task.sleep(for: pollInterval)
      }
    }

    static func attemptMerge(
      _ grouping: HarnessMonitorStore.SessionTabGroupSnapshot,
      registry: SessionWindowAppKitRegistry = .shared
    ) -> MergeOutcome {
      let windowsBySessionID = Dictionary(
        uniqueKeysWithValues: grouping.sessionIDs.compactMap { sessionID in
          registry.window(forSessionID: sessionID).map { (sessionID, $0) }
        }
      )
      let tabReadyWindows = grouping.sessionIDs.compactMap { sessionID -> NSWindow? in
        guard let window = windowsBySessionID[sessionID], isWindowTabReady(window) else {
          return nil
        }
        return window
      }
      let missingTabReadySessionIDs = grouping.sessionIDs.filter { sessionID in
        guard let window = windowsBySessionID[sessionID] else {
          return true
        }
        return !isWindowTabReady(window)
      }

      if let anchor = tabReadyWindows.first, tabReadyWindows.count > 1 {
        for next in tabReadyWindows.dropFirst() {
          guard next !== anchor else { continue }
          // Skip if AppKit already merged them (matching tabbingIdentifier
          // + user pref Always reaches us with a tab group already formed).
          if let group = anchor.tabGroup, group === next.tabGroup {
            continue
          }
          anchor.addTabbedWindow(next, ordered: .above)
        }
      }

      let resolved = isGroupingResolved(grouping, registry: registry)
      var foregroundResolved = false
      if resolved,
        let foregroundID = grouping.foregroundSessionID,
        let foregroundWindow = registry.window(forSessionID: foregroundID),
        let tabGroup = foregroundWindow.tabGroup
      {
        tabGroup.selectedWindow = foregroundWindow
        foregroundResolved = true
      }

      return MergeOutcome(
        resolved: resolved,
        foregroundResolved: foregroundResolved,
        missingTabReadySessionIDs: missingTabReadySessionIDs
      )
    }

    static func isGroupingResolved(
      _ grouping: HarnessMonitorStore.SessionTabGroupSnapshot,
      registry: SessionWindowAppKitRegistry = .shared
    ) -> Bool {
      let windows = grouping.sessionIDs.compactMap { sessionID in
        registry.window(forSessionID: sessionID)
      }
      guard windows.count == grouping.sessionIDs.count,
        let anchorTabGroup = windows.first?.tabGroup
      else {
        return false
      }
      return windows.allSatisfy { $0.tabGroup === anchorTabGroup }
    }

    static func isWindowTabReady(_ window: NSWindow) -> Bool {
      window.toolbar != nil
        && window.tabbingIdentifier == SessionWindowTabbingSupport.tabbingIdentifier
    }
  }
#endif
