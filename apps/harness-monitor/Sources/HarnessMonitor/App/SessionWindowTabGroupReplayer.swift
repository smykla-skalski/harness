#if canImport(AppKit)
  import AppKit
  import HarnessMonitorKit
  import HarnessMonitorUIPreviewable

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

    struct WindowReadinessSnapshot: Equatable {
      let boundSessionIDCount: Int
      let tabReadySessionIDCount: Int
      let toolbarsReady: Bool
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

        let readiness = scanWindowReadiness(
          expectedSessionIDs: expectedSessionIDs,
          registry: registry
        )
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
          boundSessionIDCount: readiness.boundSessionIDCount,
          tabReadySessionIDCount: readiness.tabReadySessionIDCount,
          toolbarsReady: readiness.toolbarsReady,
          resolvedGroupCount: resolvedOrdinals.count,
          foregroundResolvedCount: foregroundResolvedOrdinals.count
        )
        if resolvedOrdinals.count == groupings.count || ContinuousClock.now >= deadline {
          return replayOutcome
        }

        do {
          try await Task.sleep(for: pollInterval)
        } catch {
          return replayOutcome
        }
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
          normalizeTabOrder(
            anchor: dashboardWindow,
            desiredWindows: [dashboardWindow] + tabReadyWindows
          )
        }
      } else if let anchor = tabReadyWindows.first, tabReadyWindows.count > 1 {
        normalizeTabOrder(anchor: anchor, desiredWindows: tabReadyWindows)
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
          && tabOrderMatches(
            expectedWindows: [dashboardWindow] + windows,
            in: anchorTabGroup
          )
      }
      guard let anchorTabGroup = windows.first?.tabGroup else {
        return false
      }
      return windows.allSatisfy { $0.tabGroup === anchorTabGroup }
        && tabOrderMatches(expectedWindows: windows, in: anchorTabGroup)
    }

    static func isWindowTabReady(_ window: NSWindow) -> Bool {
      window.tabbingIdentifier == SessionWindowTabbingSupport.tabbingIdentifier
    }

    private static func scanWindowReadiness(
      expectedSessionIDs: Set<String>,
      registry: SessionWindowAppKitRegistry
    ) -> WindowReadinessSnapshot {
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
      return WindowReadinessSnapshot(
        boundSessionIDCount: boundSessionIDCount,
        tabReadySessionIDCount: tabReadySessionIDCount,
        toolbarsReady: toolbarsReady
      )
    }

    private static func normalizeTabOrder(
      anchor: NSWindow,
      desiredWindows: [NSWindow]
    ) {
      guard desiredWindows.count > 1 else { return }
      for next in desiredWindows.dropFirst().reversed() {
        guard next !== anchor else { continue }
        anchor.tabGroup?.selectedWindow = anchor
        anchor.addTabbedWindow(next, ordered: .above)
      }
    }

    private static func tabOrderMatches(
      expectedWindows: [NSWindow],
      in tabGroup: NSWindowTabGroup
    ) -> Bool {
      tabGroup.windows.elementsEqual(expectedWindows, by: { $0 === $1 })
    }
  }
#endif
