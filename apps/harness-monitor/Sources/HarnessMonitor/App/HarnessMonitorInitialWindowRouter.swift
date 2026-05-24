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
  let openWelcomeWindow: (Bool) -> Void
  let openSessionWindow: (String, Bool) -> Void

  // Upper bound for SwiftUI's `WindowGroup(id:for:)` restoration to bind
  // every restored session window. 1.5 s was sized against Apple Silicon
  // hardware with cold disk caches and FileVault on during development of
  // 903a0eec0; the prior 6 x 50 ms (300 ms) budget regularly expired before
  // restored windows registered. If this budget proves too short in real use,
  // prefer collapsing the two registries (or finding a SwiftUI
  // restoration-complete signal) over raising the timeout further.
  static let restorationWaitTimeout: Duration = .milliseconds(1500)
  static let restorationRecoveryTimeout: Duration = .seconds(10)
  static let restorationRecoveryPollInterval: Duration = .milliseconds(100)
  private static var replayRecoveryTask: Task<Void, Never>?
  private static var replayRecoveryTaskGeneration = 0

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
      openWelcomeWindow(false)
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
    guard
      launchBehavior == .restoreSessionWindows,
      !restorePlan.sessionIDs.isEmpty || !dashboardTabRestoreState.sessionIDs.isEmpty
    else {
      return false
    }
    guard await waitForVisibleSessionWindowDuringLaunch() else {
      return false
    }
    if shouldRestoreDashboard {
      openWelcomeWindow(false)
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
        openWelcomeWindow(false)
      }
    case .welcome:
      openWelcomeWindow(launchBehavior != .restoreSessionWindows)
    case .sessions(let sessionIDs):
      if shouldRestoreDashboard {
        openWelcomeWindow(false)
      }
      for sessionID in sessionIDs {
        openSessionWindow(sessionID, false)
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
    #if canImport(AppKit)
      let registry = SessionWindowAppKitRegistry.shared
      let replayRestorePlan = Self.effectiveReplayRestorePlan(
        in: restorePlan,
        dashboardTabRestoreState: dashboardTabRestoreState,
        liveBoundSessionIDs: registry.currentBindings().map(\.sessionID)
      )
      let replayGroupings = Self.replayGroupings(
        in: replayRestorePlan,
        shouldRestoreDashboard: shouldRestoreDashboard,
        dashboardTabRestoreState: dashboardTabRestoreState
      )
      guard !replayGroupings.isEmpty else { return }
      let expectedSessionIDs = Set(replayGroupings.flatMap { $0.sessionIDs })
      // Edge-triggered: returns as soon as every expected sessionID has an
      // NSWindow bound, falling back to the timeout. Replaces the previous
      // 30 x 50 ms polling loop.
      _ = await registry.waitForBindings(
        satisfying: { sessionIDs in expectedSessionIDs.isSubset(of: sessionIDs) },
        timeout: Self.restorationWaitTimeout
      )
      let replayOutcome = await SessionWindowTabGroupReplayer.replay(
        replayGroupings,
        registry: registry,
        dashboardWindowProvider: { DashboardWindowAppKitRegistry.shared.window },
        timeout: Self.restorationWaitTimeout
      )
      guard replayOutcome.resolvedGroupCount < replayGroupings.count else {
        return
      }
      Self.scheduleReplayRecovery(
        replayGroupings,
        registry: registry
      )
    #else
      let replayGroupings = Self.replayGroupings(
        in: restorePlan,
        shouldRestoreDashboard: shouldRestoreDashboard,
        dashboardTabRestoreState: dashboardTabRestoreState
      )
      guard !replayGroupings.isEmpty else { return }
    #endif
  }

  private static func scheduleReplayRecovery(
    _ replayGroupings: [HarnessMonitorStore.SessionTabGroupSnapshot],
    registry: SessionWindowAppKitRegistry
  ) {
    replayRecoveryTask?.cancel()
    replayRecoveryTaskGeneration += 1
    let generation = replayRecoveryTaskGeneration
    replayRecoveryTask = Task { @MainActor in
      defer {
        if replayRecoveryTaskGeneration == generation {
          replayRecoveryTask = nil
        }
      }
      _ = await SessionWindowTabGroupReplayer.replay(
        replayGroupings,
        registry: registry,
        dashboardWindowProvider: { DashboardWindowAppKitRegistry.shared.window },
        timeout: restorationRecoveryTimeout,
        pollInterval: restorationRecoveryPollInterval
      )
    }
  }

  static func waitForReplayRecoveryForTesting() async {
    await replayRecoveryTask?.value
  }

  static func resetReplayRecoveryForTesting() {
    replayRecoveryTask?.cancel()
    replayRecoveryTask = nil
    replayRecoveryTaskGeneration = 0
  }

  static func effectiveReplayRestorePlan(
    in restorePlan: HarnessMonitorStore.LaunchWindowRestorePlan,
    dashboardTabRestoreState: DashboardWindowLifecycleTracker.TabRestoreState,
    liveBoundSessionIDs: [String]
  ) -> HarnessMonitorStore.LaunchWindowRestorePlan {
    var orderedSessionIDs = restorePlan.sessionIDs
    var seen = Set(orderedSessionIDs)

    for sessionID in dashboardTabRestoreState.sessionIDs where seen.insert(sessionID).inserted {
      orderedSessionIDs.append(sessionID)
    }
    for sessionID in liveBoundSessionIDs where seen.insert(sessionID).inserted {
      orderedSessionIDs.append(sessionID)
    }

    guard orderedSessionIDs != restorePlan.sessionIDs else {
      return restorePlan
    }

    return HarnessMonitorStore.LaunchWindowRestorePlan(
      sessionIDs: orderedSessionIDs,
      usedBridgeFallback: restorePlan.usedBridgeFallback,
      tabGroupings: restorePlan.tabGroupings
    )
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

  private func waitForVisibleSessionWindowDuringLaunch() async -> Bool {
    if hasVisibleSessionWindows() { return true }
    #if canImport(AppKit)
      // SwiftUI window restoration runs asynchronously after launch and on
      // real machines the original 6 x 50 ms (300 ms) polling budget often
      // expired before restored session windows registered, so the router
      // fell through to Welcome and the user saw both. The registry's
      // edge-triggered waiter wakes on the first matching `bind(...)` so
      // warm launches finish on the first event; cold launches stay
      // bounded by the timeout.
      let converged = await SessionWindowAppKitRegistry.shared.waitForBindings(
        satisfying: { boundIDs in !boundIDs.isEmpty },
        timeout: Self.restorationWaitTimeout
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
