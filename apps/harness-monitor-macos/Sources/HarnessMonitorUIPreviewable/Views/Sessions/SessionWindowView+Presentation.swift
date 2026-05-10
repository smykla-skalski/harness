import HarnessMonitorKit
import SwiftUI

struct SessionWindowSnapshotRefreshTrigger: Equatable {
  let sessionID: String
  let connectionState: HarnessMonitorStore.ConnectionState
  let summaryUpdatedAt: String?
}

struct SessionWindowDecisionCacheStorage {
  var allSessionDecisions: [Decision] = []
  var matchingDecisions: [Decision] = []
  var allSessionDecisionIDs: Set<String> = []
  var matchingDecisionIDs: Set<String> = []
  var detailRenderedSelection: SessionSelection?
  var contentRenderedRoute: SessionWindowRoute?
}

extension SessionWindowView {
  func sessionWindowLifecycleModifiers<Content: View>(
    _ content: Content
  ) -> some View {
    content
      .navigationTitle(navigationTitleText)
      .navigationSubtitle(navigationSubtitleText)
      .onChange(of: focusMode) { _, _ in
        reconcileInspectorVisibility(
          visibleBinding: inspectorVisibleBinding,
          preferredBinding: inspectorPreferredBinding
        )
      }
      .task(id: snapshotRefreshTrigger) {
        await refreshSnapshot(for: snapshotRefreshTrigger)
      }
      .task(id: decisionsCacheTrigger) {
        await recomputeDecisionsCache()
      }
      .task(id: store.pendingSessionRouteRequestID) {
        await applyPendingSessionRouteIfNeeded()
      }
  }

  func route(for selection: SessionSelection) -> SessionWindowRoute {
    switch selection {
    case .route(let route): route
    case .agent: .agents
    case .codexRun: .agents
    case .decision: .decisions
    case .task: .tasks
    case .create: .agents
    }
  }

  var summary: SessionSummary? {
    catalogSummary ?? snapshot?.summary
  }

  var catalogSummary: SessionSummary? {
    store.sessionIndex.sessionSummary(for: token.sessionID)
  }

  var snapshotRefreshTrigger: SessionWindowSnapshotRefreshTrigger {
    SessionWindowSnapshotRefreshTrigger(
      sessionID: token.sessionID,
      connectionState: store.connectionState,
      summaryUpdatedAt: catalogSummary?.updatedAt
    )
  }

  var navigationTitleText: String {
    summary?.displayTitle ?? "Session"
  }

  var navigationSubtitleText: String {
    summary?.projectAndWorktreeDisplayLabel(separator: "·") ?? ""
  }

  var allSessionDecisions: [Decision] {
    allSessionDecisionsCache
  }

  var matchingDecisions: [Decision] {
    matchingDecisionsCache
  }

  var selectedDecision: Decision? {
    stateCache.selectedDecision(in: allSessionDecisionsCache)
  }

  var selectedDecisionVisibility: SessionSelectedDecisionVisibility {
    stateCache.selectedDecisionVisibility(
      allDecisionIDs: allSessionDecisionIDsCache,
      visibleDecisionIDs: matchingDecisionIDsCache
    )
  }

  var selectedDecisionHiddenByFilters: Bool {
    selectedDecisionVisibility == .hidden
  }

  var sessionDecisionDetailID: String? {
    switch stateCache.selection {
    case .decision(_, let decisionID):
      decisionID
    case .route(.decisions):
      stateCache.sectionState.decisionID
    default:
      nil
    }
  }

  var sessionDecisionDetail: Decision? {
    guard let sessionDecisionDetailID else {
      return nil
    }
    return allSessionDecisionsCache.first { $0.id == sessionDecisionDetailID }
  }

  var sessionDecisionDetailHiddenByFilters: Bool {
    guard let sessionDecisionDetailID else {
      return false
    }
    return allSessionDecisionIDsCache.contains(sessionDecisionDetailID)
      && !matchingDecisionIDsCache.contains(sessionDecisionDetailID)
  }

  var sessionDecisionObserver: ObserverSummary? {
    snapshot?.detail?.observer
  }

  var sessionDecisionVisibleSnapshot: DecisionsSidebarViewModel.VisibleSnapshot {
    let filters = stateCache.decisionFilters.decisionWorkspaceFilters
    let signature = DecisionsSidebarViewModel.visibleSnapshot(
      decisions: allSessionDecisionsCache,
      filters: filters
    ).signature
    let groups =
      matchingDecisionsCache.isEmpty
      ? []
      : [
        DecisionsSidebarViewModel.SessionGroup(
          sessionID: token.sessionID, decisions: matchingDecisionsCache)
      ]
    return DecisionsSidebarViewModel.VisibleSnapshot(
      groups: groups,
      decisionIDs: matchingDecisionsCache.map(\.id),
      signature: signature
    )
  }

  var sessionDecisionScope: DecisionWorkspaceScope {
    DecisionWorkspaceScope(
      decisions: allSessionDecisionsCache,
      filters: stateCache.decisionFilters.decisionWorkspaceFilters,
      visibleSnapshot: sessionDecisionVisibleSnapshot,
      selectedDecisionID: sessionDecisionDetailID
    )
  }

  var inspectorContextDecision: Decision? {
    guard case .decision = stateCache.selection else {
      return nil
    }
    return selectedDecision
  }

  var canPresentInspector: Bool {
    guard !focusMode, inspectorContextDecision != nil else {
      return false
    }
    guard detailColumnWidth > 0 else {
      return false
    }
    return stateCache.decisionRuntime.allowsInspector(width: detailColumnWidth)
  }

  @ToolbarContentBuilder var sessionToolbar: some ToolbarContent {
    SessionWindowToolbar(
      store: store,
      model: sessionToolbarModel,
      focusModeStatusModel: focusMode ? sessionStatusSummaryModel : nil,
      state: stateCache,
      focusMode: focusModeBinding
    )
  }

  var sessionToolbarModel: SessionWindowToolbarModel {
    let toolbar = store.contentUI.toolbar
    return SessionWindowToolbarModel(
      canNavigateBack: toolbar.canNavigateBack,
      canNavigateForward: toolbar.canNavigateForward,
      sleepPreventionPresentation: SleepPreventionToolbarPresentation(
        isEnabled: toolbar.sleepPreventionEnabled
      )
    )
  }

  var sessionStatusSummaryModel: SessionStatusSummaryModel {
    let chrome = store.contentUI.chrome
    let metrics = store.connectionMetrics
    let sourceTitle: String =
      if snapshot == nil {
        "Loading"
      } else if isLoading || snapshot?.source == nil {
        "Refreshing"
      } else {
        snapshot?.source.rawValue.capitalized ?? "Loading"
      }
    let sourceTint: SessionStatusSourceTint =
      if isLoading || snapshot?.source == nil {
        .tertiary
      } else {
        switch snapshot?.source {
        case .live:
          sessionStatusSourceTint(for: metrics)
        case .cache:
          sessionStatusSourceTint(for: metrics)
        case .catalog:
          .tertiary
        case .none:
          .tertiary
        }
      }
    let connectionSummaryText =
      if metrics.connectedSince != nil {
        if let latency = metrics.transportLatencyMs {
          "Connection: \(metrics.transportKind.title), transport latency \(latency) milliseconds"
        } else if let requestLatency = metrics.requestLatencyMs {
          [
            "Connection: \(metrics.transportKind.title)",
            "transport latency unavailable,",
            "last request latency \(requestLatency) milliseconds",
          ].joined(separator: " ")
        } else {
          "Connection: \(metrics.transportKind.title)"
        }
      } else {
        "Connection: \(connectionTitle)"
      }
    return SessionStatusSummaryModel(
      metrics: metrics,
      sourceTitle: sourceTitle,
      sourceSystemImage: sourceSystemImage,
      sourceTint: sourceTint,
      statusStripState: SessionStatusStripState(
        daemonOwnership: store.daemonOwnership,
        bridgeRunning: store.daemonStatus?.manifest?.hostBridge.running == true,
        mcpStatus: chrome.mcpStatus,
        isMCPRegistryHostEnabled: mcpRegistryHostEnabled
      ),
      connectionSummaryText: connectionSummaryText,
      sessionStatusTitle: summary?.status.title ?? "Loading"
    )
  }

  private func sessionStatusSourceTint(for metrics: ConnectionMetrics) -> SessionStatusSourceTint {
    if metrics.usesMutedConnectionChrome {
      return .disabledConnection
    }
    let quality: ConnectionQuality =
      if metrics.transportLatencyMs != nil {
        metrics.transportQuality
      } else if metrics.requestLatencyMs != nil {
        metrics.requestQuality
      } else {
        .disconnected
      }
    switch quality {
    case .excellent, .good:
      return .success
    case .degraded:
      return .caution
    case .poor, .disconnected:
      return .danger
    }
  }

  var columnVisibilityBinding: Binding<NavigationSplitViewVisibility> {
    Binding(
      get: {
        let decodedVisibility = SessionColumnVisibilityCodec.decode(columnVisibilityRaw)
        return decodedVisibility == .all ? .doubleColumn : decodedVisibility
      },
      set: { newValue in
        let storedVisibility: NavigationSplitViewVisibility =
          newValue == .all ? .doubleColumn : newValue
        columnVisibilityRaw = SessionColumnVisibilityCodec.encode(storedVisibility)
      }
    )
  }

  var focusModeColumnVisibilityBinding: Binding<NavigationSplitViewVisibility> {
    Binding(
      get: {
        focusMode
          ? .detailOnly
          : columnVisibilityBinding.wrappedValue
      },
      set: { newValue in
        guard !focusMode else { return }
        columnVisibilityBinding.wrappedValue = newValue
      }
    )
  }

  @MainActor
  func refreshSnapshot(for trigger: SessionWindowSnapshotRefreshTrigger) async {
    guard trigger.sessionID == token.sessionID else { return }
    if didLoadSnapshot {
      await loadSnapshot()
    } else {
      await performInitialLoad()
    }
  }

  @MainActor
  func performInitialLoad() async {
    hydrateSelectionFromPersistedStorage()
    hydrateDecisionFiltersFromPersistedStorage()
    await applyPendingSessionRouteIfNeeded()
    reconcileInspectorVisibility(
      visibleBinding: inspectorVisibleBinding,
      preferredBinding: inspectorPreferredBinding,
      announce: false
    )
    await loadSnapshot()
    requestPrimaryContentAccessibilityFocus()
    reconcileInspectorVisibility(
      visibleBinding: inspectorVisibleBinding,
      preferredBinding: inspectorPreferredBinding,
      announce: false
    )
  }

  var sourceSystemImage: String {
    guard !isLoading, let source = snapshot?.source else {
      return "arrow.clockwise"
    }
    switch source {
    case .live:
      return "bolt.horizontal.circle"
    case .cache:
      return "externaldrive"
    case .catalog:
      return "square.stack.3d.up"
    }
  }

  var connectionTitle: String {
    switch store.connectionState {
    case .idle: "Idle"
    case .connecting: "Connecting"
    case .online: "Online"
    case .offline: "Offline"
    }
  }

  func loadSnapshot() async {
    guard !Task.isCancelled else { return }
    isLoading = true
    defer { isLoading = false }
    await store.bootstrapIfNeeded()
    guard !Task.isCancelled else { return }
    let nextSnapshot = await store.sessionWindowSnapshot(sessionID: token.sessionID)
    guard !Task.isCancelled else { return }
    snapshot = nextSnapshot
    didLoadSnapshot = true
  }

  func encodedDecisionSeverities(_ severities: Set<DecisionSeverity>) -> String {
    severities.map(\.rawValue).sorted().joined(separator: ",")
  }

  func agentTui(for agent: AgentRegistration) -> AgentTuiSnapshot? {
    store.selectedAgentTuis.first { tui in
      tui.sessionId == token.sessionID
        && (tui.sessionAgentID == agent.agentId
          || tui.managedAgentID == agent.managedAgentID
          || tui.tuiId == agent.managedAgentID)
    }
  }
}
