import HarnessMonitorKit
import SwiftUI

struct SessionWindowSnapshotRefreshTrigger: Equatable {
  let sessionID: String
  let connectionState: HarnessMonitorStore.ConnectionState
  let summaryUpdatedAt: String?
}

struct SessionWindowManagedTranscriptRefreshTrigger: Equatable {
  let sessionID: String
  let connectionState: HarnessMonitorStore.ConnectionState
  let codexRuns: [SessionWindowCodexRunTranscriptRefreshKey]

  var hasManagedRuntimeUpdates: Bool {
    !codexRuns.isEmpty
  }
}

struct SessionWindowPendingRouteTrigger: Equatable {
  let requestID: Int
  let didLoadSnapshot: Bool
}

struct SessionWindowCodexRunTranscriptRefreshKey: Equatable {
  let runID: String
  let status: CodexRunStatus
  let updatedAt: String
  let eventCount: Int
}

struct SessionWindowDecisionCacheStorage {
  var allSessionDecisions: [Decision] = []
  var allSessionDecisionPresentationItems: [DecisionPresentationSnapshot] = []
  var allSessionDecisionSearchProjections: [DecisionSearchProjection] = []
  var matchingDecisions: [Decision] = []
  var matchingDecisionPresentationItems: [DecisionPresentationSnapshot] = []
  var allSessionDecisionIDs: Set<String> = []
  var allSessionDecisionIDsInOrder: [String] = []
  var matchingDecisionIDs: Set<String> = []
  var matchingDecisionIDsInOrder: [String] = []
  var detailRenderedSelection: SessionSelection?
  var contentRenderedRoute: SessionWindowRoute?
}

extension SessionWindowView {
  func sessionWindowLifecycleModifiers<Content: View>(
    _ content: Content
  ) -> some View {
    let routeTrigger = pendingRouteTrigger

    return
      content
      .navigationTitle(navigationTitleText)
      .navigationSubtitle(navigationSubtitleText)
      .sessionTitleBlurChrome(
        status: summary?.status ?? .awaitingLeader,
        isStale: snapshot == nil
      )
      .onChange(of: focusMode) { _, _ in
        reconcileInspectorVisibility(
          visibleBinding: inspectorVisibleBinding,
          preferredBinding: inspectorPreferredBinding
        )
      }
      .task(id: snapshotRefreshTrigger) {
        await refreshSnapshot(for: snapshotRefreshTrigger)
      }
      .task(id: managedTranscriptRefreshTrigger) {
        await refreshManagedTranscript(for: managedTranscriptRefreshTrigger)
      }
      .task(id: decisionsRefreshTrigger) {
        await refreshDecisionsCache()
      }
      .task(id: decisionFilterTrigger) {
        await refilterDecisionsCache()
      }
      .task(id: routeTrigger) {
        guard routeTrigger.didLoadSnapshot else { return }
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

  var managedTranscriptRefreshTrigger: SessionWindowManagedTranscriptRefreshTrigger {
    SessionWindowManagedTranscriptRefreshTrigger(
      sessionID: token.sessionID,
      connectionState: store.connectionState,
      codexRuns: sessionCodexRuns.map {
        SessionWindowCodexRunTranscriptRefreshKey(
          runID: $0.runId,
          status: $0.status,
          updatedAt: $0.updatedAt,
          eventCount: $0.events.count
        )
      }
    )
  }

  var pendingRouteTrigger: SessionWindowPendingRouteTrigger {
    SessionWindowPendingRouteTrigger(
      requestID: store.pendingSessionRouteRequestID,
      didLoadSnapshot: didLoadSnapshot
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
    let signature = DecisionsSidebarViewModel.filterSignature(filters: filters)
    let groups =
      matchingDecisionsCache.isEmpty
      ? []
      : [
        DecisionsSidebarViewModel.SessionGroup(
          sessionID: token.sessionID, decisions: matchingDecisionsCache)
      ]
    return DecisionsSidebarViewModel.VisibleSnapshot(
      groups: groups,
      decisionIDs: matchingDecisionIDsInOrderCache,
      signature: signature
    )
  }

  var sessionDecisionScope: DecisionWorkspaceScope {
    DecisionWorkspaceScope(
      decisions: allSessionDecisionsCache,
      decisionsByID: store.supervisorOpenDecisionsByID,
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
      state: stateCache,
      focusMode: focusModeBinding,
      currentModifiers: presentedModifiers
    )
  }

  var sessionToolbarModel: SessionWindowToolbarModel {
    SessionWindowToolbarModel(
      canNavigateBack: stateCache.navigationHistory.canGoBack,
      canNavigateForward: stateCache.navigationHistory.canGoForward,
      sleepPreventionPresentation: SleepPreventionToolbarPresentation(
        isEnabled: store.contentUI.toolbar.sleepPreventionEnabled
      )
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
  func refreshManagedTranscript(for trigger: SessionWindowManagedTranscriptRefreshTrigger) async {
    guard trigger.sessionID == token.sessionID else { return }
    guard didLoadSnapshot, trigger.connectionState == .online else { return }
    guard trigger.hasManagedRuntimeUpdates else { return }
    try? await Task.sleep(for: .milliseconds(120))
    guard !Task.isCancelled, let currentSnapshot = snapshot else { return }
    guard
      let nextSnapshot = await store.refreshSessionWindowManagedTranscript(
        sessionID: token.sessionID,
        snapshot: currentSnapshot
      )
    else {
      return
    }
    guard !Task.isCancelled else { return }
    snapshot = nextSnapshot
    didLoadSnapshot = true
  }

  @MainActor
  func performInitialLoad() async {
    hydrateSelectionFromPersistedStorage()
    hydrateDecisionFiltersFromPersistedStorage()
    await applyPendingSessionRouteIfNeeded()
    await loadSnapshot()
    requestPrimaryContentAccessibilityFocus()
    enableStartupSearchParticipation()
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

  func agentTui(for agent: AgentRegistration) -> AgentTuiSnapshot? {
    store.selectedAgentTuis.first { tui in
      tui.sessionId == token.sessionID
        && (tui.sessionAgentID == agent.agentId
          || tui.managedAgentID == agent.managedAgentID
          || tui.tuiId == agent.managedAgentID)
    }
  }
}
