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
    let dashboardTabRestoreState = DashboardWindowLifecycleTracker.tabRestoreStateAtQuit()
    let restorePlan = await prepareRestorePlan()

    if await restoreVisibleWindowsIfNeeded(
      shouldRestoreDashboard: shouldRestoreDashboard,
      dashboardTabRestoreState: dashboardTabRestoreState,
      restorePlan: restorePlan
    ) {
      return
    }
    if await restoreAutoRestoredWindowsIfNeeded(
      shouldRestoreDashboard: shouldRestoreDashboard,
      dashboardTabRestoreState: dashboardTabRestoreState,
      restorePlan: restorePlan
    ) {
      return
    }
    await routeInitialPlan(
      shouldRestoreDashboard: shouldRestoreDashboard,
      dashboardTabRestoreState: dashboardTabRestoreState,
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
    dashboardTabRestoreState: DashboardWindowLifecycleTracker.TabRestoreState,
    restorePlan: HarnessMonitorStore.LaunchWindowRestorePlan
  ) async -> Bool {
    guard launchBehavior == .restoreSessionWindows, hasVisibleSessionWindows() else {
      return false
    }
    if shouldRestoreDashboard {
      openWelcomeWindow()
    }
    await replayTabGroupingsIfNeeded(
      in: restorePlan,
      shouldRestoreDashboard: shouldRestoreDashboard,
      dashboardTabRestoreState: dashboardTabRestoreState
    )
    return true
  }

  private func restoreAutoRestoredWindowsIfNeeded(
    shouldRestoreDashboard: Bool,
    dashboardTabRestoreState: DashboardWindowLifecycleTracker.TabRestoreState,
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
    await replayTabGroupingsIfNeeded(
      in: restorePlan,
      shouldRestoreDashboard: shouldRestoreDashboard,
      dashboardTabRestoreState: dashboardTabRestoreState
    )
    return true
  }

  private func routeInitialPlan(
    shouldRestoreDashboard: Bool,
    dashboardTabRestoreState: DashboardWindowLifecycleTracker.TabRestoreState,
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
      await replayTabGroupingsIfNeeded(
        in: restorePlan,
        shouldRestoreDashboard: shouldRestoreDashboard,
        dashboardTabRestoreState: dashboardTabRestoreState
      )
    }

    if initialPlan.shouldMarkBridgeFallbackComplete {
      store.completeLaunchWindowBridgeFallback()
    }
  }

  private func replayTabGroupingsIfNeeded(
    in restorePlan: HarnessMonitorStore.LaunchWindowRestorePlan,
    shouldRestoreDashboard: Bool,
    dashboardTabRestoreState: DashboardWindowLifecycleTracker.TabRestoreState
  ) async {
    guard tabbingPreference != .never else { return }
    let replayGroupings = Self.replayGroupings(
      in: restorePlan,
      shouldRestoreDashboard: shouldRestoreDashboard,
      dashboardTabRestoreState: dashboardTabRestoreState
    )
    guard !replayGroupings.isEmpty else { return }
    #if canImport(AppKit)
      let expectedSessionIDs = Set(replayGroupings.flatMap { $0.sessionIDs })
      let registry = SessionWindowAppKitRegistry.shared
      // Edge-triggered: returns as soon as every expected sessionID has an
      // NSWindow bound, falling back to the timeout. Replaces the previous
      // 30 x 50 ms polling loop.
      let converged = await registry.waitForBindings(
        satisfying: { sessionIDs in expectedSessionIDs.isSubset(of: sessionIDs) },
        timeout: Self.restorationWaitTimeout
      )
      let replayOutcome = await SessionWindowTabGroupReplayer.replay(
        replayGroupings,
        registry: registry,
        dashboardWindowProvider: { DashboardWindowAppKitRegistry.shared.window },
        timeout: Self.restorationWaitTimeout
      )

      let foregroundExpectedCount = replayGroupings.reduce(into: 0) { count, grouping in
        if grouping.foregroundSessionID != nil || grouping.dashboardWasForeground {
          count += 1
        }
      }
      HarnessMonitorLogger.lifecycle.info(
        """
        tab-grouping replay groups=\(replayGroupings.count, privacy: .public) \
        expected_members=\(expectedSessionIDs.count, privacy: .public) \
        bound_members=\(replayOutcome.boundSessionIDCount, privacy: .public) \
        missed_members=\(expectedSessionIDs.count - replayOutcome.boundSessionIDCount, privacy: .public) \
        toolbars_ready=\(replayOutcome.toolbarsReady, privacy: .public) \
        tab_ready_members=\(replayOutcome.tabReadySessionIDCount, privacy: .public) \
        groups_resolved=\(replayOutcome.resolvedGroupCount, privacy: .public)/\
        \(replayGroupings.count, privacy: .public) \
        foreground_resolved=\(replayOutcome.foregroundResolvedCount, privacy: .public)/\
        \(foregroundExpectedCount, privacy: .public) \
        attempts=\(replayOutcome.attempts, privacy: .public) \
        converged=\(converged, privacy: .public)
        """
      )
    #endif
  }

  static func replayGroupings(
    in restorePlan: HarnessMonitorStore.LaunchWindowRestorePlan,
    shouldRestoreDashboard: Bool,
    dashboardTabRestoreState: DashboardWindowLifecycleTracker.TabRestoreState
  ) -> [HarnessMonitorStore.SessionTabGroupSnapshot] {
    var replayGroupings = restorePlan.tabGroupings
    guard shouldRestoreDashboard else {
      return replayGroupings
    }

    let knownSessionIDs = Set(restorePlan.sessionIDs)
    let survivingDashboardSessionIDs = dashboardTabRestoreState.sessionIDs.filter {
      knownSessionIDs.contains($0)
    }
    guard !survivingDashboardSessionIDs.isEmpty else {
      return replayGroupings
    }

    if let existingIndex = replayGroupings.firstIndex(where: {
      Set($0.sessionIDs) == Set(survivingDashboardSessionIDs)
    }) {
      let grouping = replayGroupings[existingIndex]
      replayGroupings[existingIndex] = HarnessMonitorStore.SessionTabGroupSnapshot(
        ordinal: grouping.ordinal,
        sessionIDs: survivingDashboardSessionIDs,
        foregroundSessionID: replayForegroundSessionID(
          grouping: grouping,
          survivingDashboardSessionIDs: survivingDashboardSessionIDs,
          dashboardTabRestoreState: dashboardTabRestoreState
        ),
        includesDashboard: true,
        dashboardWasForeground: dashboardTabRestoreState.wasForegroundTab
      )
    } else {
      let syntheticOrdinal = (replayGroupings.map(\.ordinal).max() ?? -1) + 1
      replayGroupings.append(
        HarnessMonitorStore.SessionTabGroupSnapshot(
          ordinal: syntheticOrdinal,
          sessionIDs: survivingDashboardSessionIDs,
          foregroundSessionID: replayForegroundSessionID(
            grouping: nil,
            survivingDashboardSessionIDs: survivingDashboardSessionIDs,
            dashboardTabRestoreState: dashboardTabRestoreState
          ),
          includesDashboard: true,
          dashboardWasForeground: dashboardTabRestoreState.wasForegroundTab
        )
      )
    }

    return replayGroupings
  }

  private static func replayForegroundSessionID(
    grouping: HarnessMonitorStore.SessionTabGroupSnapshot?,
    survivingDashboardSessionIDs: [String],
    dashboardTabRestoreState: DashboardWindowLifecycleTracker.TabRestoreState
  ) -> String? {
    guard !dashboardTabRestoreState.wasForegroundTab else {
      return nil
    }
    if let grouping,
      let foregroundSessionID = grouping.foregroundSessionID,
      survivingDashboardSessionIDs.contains(foregroundSessionID)
    {
      return foregroundSessionID
    }
    if survivingDashboardSessionIDs.count == 1 {
      return survivingDashboardSessionIDs[0]
    }
    return nil
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
      dashboardWindowProvider: @MainActor () -> NSWindow? = { nil },
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
      // Once a grouping resolves, skip it in subsequent polls — otherwise the
      // tabGroup.selectedWindow write inside attemptMerge fires on every tick
      // and cascades through AppKit's KVO into SwiftUI's MergedEnvironment
      // graph (see r16 audit: 34k MergedEnvironment edges traced back to
      // pencil.and.list.clipboard fanout during the polling window).
      var resolvedOrdinals: Set<Int> = []
      var foregroundResolvedOrdinals: Set<Int> = []

      while true {
        attempts += 1

        var boundSessionIDCount = 0
        var tabReadySessionIDCount = 0
        // Toolbar attachment is only an observational metric here. Replay
        // eligibility is the shared tabbing identifier, because SwiftUI can
        // attach unified toolbar chrome after a restored window is already
        // ready to join its tab group.
        var toolbarsReady = true
        // Single pass over expectedSessionIDs replaces three independent
        // reduce/allSatisfy walks; the registry lookup is O(1) but the loop
        // overhead and three closures per attempt added up across 30 polls.
        for sessionID in expectedSessionIDs {
          guard let window = registry.window(forSessionID: sessionID) else {
            toolbarsReady = false
            continue
          }
          boundSessionIDCount += 1
          if window.toolbar == nil {
            toolbarsReady = false
          }
          if isWindowTabReady(window) {
            tabReadySessionIDCount += 1
          }
        }

        let dashboardWindow = dashboardWindowProvider()
        for grouping in groupings where !resolvedOrdinals.contains(grouping.ordinal) {
          let mergeOutcome = attemptMerge(
            grouping,
            registry: registry,
            dashboardWindow: dashboardWindow
          )
          if mergeOutcome.resolved {
            resolvedOrdinals.insert(grouping.ordinal)
          }
          if mergeOutcome.foregroundResolved {
            foregroundResolvedOrdinals.insert(grouping.ordinal)
          }
        }

        let replayOutcome = ReplayOutcome(
          attempts: attempts,
          boundSessionIDCount: boundSessionIDCount,
          tabReadySessionIDCount: tabReadySessionIDCount,
          toolbarsReady: toolbarsReady,
          resolvedGroupCount: resolvedOrdinals.count,
          foregroundResolvedCount: foregroundResolvedOrdinals.count
        )
        if resolvedOrdinals.count == groupings.count || ContinuousClock.now >= deadline {
          return replayOutcome
        }

        try? await Task.sleep(for: pollInterval)
      }
    }

    static func attemptMerge(
      _ grouping: HarnessMonitorStore.SessionTabGroupSnapshot,
      registry: SessionWindowAppKitRegistry = .shared,
      dashboardWindow: NSWindow? = nil
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

      if grouping.includesDashboard {
        if let dashboardWindow, isWindowTabReady(dashboardWindow) {
          for next in tabReadyWindows {
            guard dashboardWindow !== next else { continue }
            if let group = dashboardWindow.tabGroup, group === next.tabGroup {
              continue
            }
            dashboardWindow.addTabbedWindow(next, ordered: .above)
          }
        }
      } else if let anchor = tabReadyWindows.first, tabReadyWindows.count > 1 {
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

      let resolved = isGroupingResolved(
        grouping,
        registry: registry,
        dashboardWindow: dashboardWindow
      )
      var foregroundResolved = false
      if resolved,
        grouping.includesDashboard,
        grouping.dashboardWasForeground,
        let dashboardWindow,
        let tabGroup = dashboardWindow.tabGroup
      {
        if tabGroup.selectedWindow !== dashboardWindow {
          tabGroup.selectedWindow = dashboardWindow
        }
        foregroundResolved = true
      } else if resolved,
        let foregroundID = grouping.foregroundSessionID,
        let foregroundWindow = registry.window(forSessionID: foregroundID),
        let tabGroup = foregroundWindow.tabGroup
      {
        // Idempotent: NSTabGroup posts KVO on selectedWindow assignment even
        // when the value is unchanged, which fans into SwiftUI's
        // MergedEnvironment graph during the polling window.
        if tabGroup.selectedWindow !== foregroundWindow {
          tabGroup.selectedWindow = foregroundWindow
        }
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
      registry: SessionWindowAppKitRegistry = .shared,
      dashboardWindow: NSWindow? = nil
    ) -> Bool {
      let windows = grouping.sessionIDs.compactMap { sessionID in
        registry.window(forSessionID: sessionID)
      }
      guard windows.count == grouping.sessionIDs.count else {
        return false
      }
      if grouping.includesDashboard {
        guard let dashboardWindow,
          isWindowTabReady(dashboardWindow),
          let anchorTabGroup = dashboardWindow.tabGroup
        else {
          return false
        }
        return windows.allSatisfy { $0.tabGroup === anchorTabGroup }
      }
      guard let anchorTabGroup = windows.first?.tabGroup else {
        return false
      }
      return windows.allSatisfy { $0.tabGroup === anchorTabGroup }
    }

    static func isWindowTabReady(_ window: NSWindow) -> Bool {
      window.tabbingIdentifier == SessionWindowTabbingSupport.tabbingIdentifier
    }
  }
#endif
