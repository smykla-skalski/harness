import HarnessMonitorKit
import SwiftUI

struct SessionWindowSnapshotRefreshTrigger: Equatable {
  let sessionID: String
  let connectionState: HarnessMonitorStore.ConnectionState
  let lastPersistedSnapshotAt: Date?
  let summaryUpdatedAt: String?
}

private struct SessionWindowDecisionCacheStorage {
  var allSessionDecisions: [Decision] = []
  var matchingDecisions: [Decision] = []
  var allSessionDecisionIDs: Set<String> = []
  var matchingDecisionIDs: Set<String> = []
  var detailRenderedSelection: SessionSelection?
  var contentRenderedRoute: SessionWindowRoute?
}

public struct SessionWindowView: View {
  public let store: HarnessMonitorStore
  public let token: SessionWindowToken
  @State private var stateCacheStorage: SessionWindowStateCache
  @Environment(\.dismiss)
  var dismiss
  @Environment(\.openWindow)
  var openWindow
  @Environment(\.undoManager)
  var undoManager
  @Environment(\.accessibilityReduceMotion)
  var reduceMotion: Bool
  @SceneStorage("session.route")
  private var persistedRoute: SessionWindowRoute = .overview
  @SceneStorage("session.decisionID")
  private var persistedDecisionID: String = ""
  @SceneStorage("session.decisionFilters.query")
  private var persistedDecisionQuery = ""
  @SceneStorage("session.focusMode")
  var focusMode = false
  @SceneStorage("session.inspector.visible")
  var inspectorVisible = false
  @SceneStorage("session.inspector.preferred")
  var inspectorPreferred = false
  @SceneStorage("session.inspector.width")
  var inspectorWidth = 280.0
  @SceneStorage("session.sidebarWidth")
  var sidebarWidth = 220.0
  @SceneStorage("session.content-detail.width")
  var contentColumnWidth = SessionContentDetailSplitLayout.defaultContentWidth
  @SceneStorage("session.columnVisibility")
  var columnVisibilityRaw = "automatic"
  @AccessibilityFocusState
  private var primaryContentAccessibilityFocused: Bool
  @State private var snapshotStorage: HarnessMonitorSessionWindowSnapshot?
  @State private var isLoadingStorage = false
  @State private var didLoadSnapshotStorage = false
  @State private var detailColumnWidthStorage: CGFloat = 0
  @State private var decisionCacheStorage = SessionWindowDecisionCacheStorage()

  public init(store: HarnessMonitorStore, token: SessionWindowToken) {
    self.store = store
    self.token = token
    _stateCacheStorage = State(wrappedValue: SessionWindowStateCache(sessionID: token.sessionID))
  }

  var stateCache: SessionWindowStateCache { stateCacheStorage }

  var snapshot: HarnessMonitorSessionWindowSnapshot? {
    get { snapshotStorage }
    nonmutating set { snapshotStorage = newValue }
  }

  var isLoading: Bool {
    get { isLoadingStorage }
    nonmutating set { isLoadingStorage = newValue }
  }

  var didLoadSnapshot: Bool {
    get { didLoadSnapshotStorage }
    nonmutating set { didLoadSnapshotStorage = newValue }
  }

  var detailColumnWidth: CGFloat {
    get { detailColumnWidthStorage }
    nonmutating set { detailColumnWidthStorage = newValue }
  }

  var allSessionDecisionsCache: [Decision] {
    get { decisionCacheStorage.allSessionDecisions }
    nonmutating set { decisionCacheStorage.allSessionDecisions = newValue }
  }

  var matchingDecisionsCache: [Decision] {
    get { decisionCacheStorage.matchingDecisions }
    nonmutating set { decisionCacheStorage.matchingDecisions = newValue }
  }

  var allSessionDecisionIDsCache: Set<String> {
    get { decisionCacheStorage.allSessionDecisionIDs }
    nonmutating set { decisionCacheStorage.allSessionDecisionIDs = newValue }
  }

  var matchingDecisionIDsCache: Set<String> {
    get { decisionCacheStorage.matchingDecisionIDs }
    nonmutating set { decisionCacheStorage.matchingDecisionIDs = newValue }
  }

  var detailRenderedSelection: SessionSelection? {
    get { decisionCacheStorage.detailRenderedSelection }
    nonmutating set { decisionCacheStorage.detailRenderedSelection = newValue }
  }

  var contentRenderedRoute: SessionWindowRoute? {
    get { decisionCacheStorage.contentRenderedRoute }
    nonmutating set { decisionCacheStorage.contentRenderedRoute = newValue }
  }

  var route: SessionWindowRoute {
    route(for: stateCache.selection)
  }

  var renderedRoute: SessionWindowRoute {
    contentRenderedRoute ?? route
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
      lastPersistedSnapshotAt: store.lastPersistedSnapshotAt,
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

  public var body: some View {
    bodyContent
      .toolbar {
        sessionToolbar
      }
  }

  @ViewBuilder
  private var bodyContent: some View {
    Group {
      if isUnknownSession {
        unknownSessionContent
      } else {
        sessionSurface
      }
    }
    .navigationTitle(navigationTitleText)
    .navigationSubtitle(navigationSubtitleText)
    .onChange(of: focusMode) { _, _ in
      reconcileInspectorVisibility(
        visibleBinding: $inspectorVisible,
        preferredBinding: $inspectorPreferred
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
    .onChange(of: stateCache.selection) { _, newSelection in
      syncPersistedStorage(from: newSelection)
      reconcileInspectorVisibility(
        visibleBinding: $inspectorVisible,
        preferredBinding: $inspectorPreferred
      )
      detailRenderedSelection = newSelection
      contentRenderedRoute = route(for: newSelection)
      if case .create(let draft) = newSelection, draft.kind == .agent {
        contentColumnWidth = SessionContentDetailSplitLayout.defaultContentWidth
      }
    }
    .onChange(of: renderedRoute) { _, newRoute in
      guard newRoute.layoutStyle == .sidebarDetail else { return }
      detailColumnWidth = 0
    }
    .onChange(of: stateCache.decisionFilters.query) { _, newValue in
      guard persistedDecisionQuery != newValue else { return }
      persistedDecisionQuery = newValue
    }
    .onChange(of: allSessionDecisions.map(\.id)) { _, _ in
      reconcileInspectorVisibility(
        visibleBinding: $inspectorVisible,
        preferredBinding: $inspectorPreferred
      )
    }
    .focusedSceneValue(\.sessionNavigation, navigationCommand)
    .focusedSceneValue(\.sessionAttention, attentionFocus)
    .focusedSceneValue(\.sessionInspector, canPresentInspector ? inspectorCommand : nil)
    .focusedSceneValue(\.sessionDecisionCommands, decisionCommand)
    .focusedSceneValue(\.sessionCreateContext, createContext)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .accessibilityElement(children: .contain)
    .accessibilityFocused($primaryContentAccessibilityFocused)
    .accessibilityIdentifier(HarnessMonitorAccessibility.sessionWindowShell)
  }

  @ToolbarContentBuilder
  private var sessionToolbar: some ToolbarContent {
    SessionWindowToolbar(
      store: store,
      snapshot: snapshot,
      isLoading: isLoading,
      summary: summary,
      connectionTitle: connectionTitle,
      sourceSystemImage: sourceSystemImage,
      state: stateCache,
      focusMode: $focusMode
    )
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

  private func hydrateSelectionFromPersistedStorage() {
    guard case .route(.overview) = stateCache.selection else { return }
    if !persistedDecisionID.isEmpty {
      stateCache.selectDecision(persistedDecisionID)
    } else if persistedRoute != .overview {
      stateCache.selectRoute(persistedRoute)
    }
  }

  private func hydrateDecisionFiltersFromPersistedStorage() {
    guard stateCache.decisionFilters.query != persistedDecisionQuery else { return }
    stateCache.decisionFilters.query = persistedDecisionQuery
  }

  @MainActor
  private func refreshSnapshot(for trigger: SessionWindowSnapshotRefreshTrigger) async {
    guard trigger.sessionID == token.sessionID else { return }
    if didLoadSnapshot {
      await loadSnapshot()
    } else {
      await performInitialLoad()
    }
  }

  @MainActor
  private func performInitialLoad() async {
    hydrateSelectionFromPersistedStorage()
    hydrateDecisionFiltersFromPersistedStorage()
    await applyPendingSessionRouteIfNeeded()
    reconcileInspectorVisibility(
      visibleBinding: $inspectorVisible,
      preferredBinding: $inspectorPreferred,
      announce: false
    )
    await loadSnapshot()
    requestPrimaryContentAccessibilityFocus()
    reconcileInspectorVisibility(
      visibleBinding: $inspectorVisible,
      preferredBinding: $inspectorPreferred,
      announce: false
    )
  }

  private func syncPersistedStorage(from selection: SessionSelection) {
    switch selection {
    case .route(let route):
      persistedRoute = route
      persistedDecisionID = ""
    case .agent:
      persistedRoute = .agents
      persistedDecisionID = ""
    case .codexRun:
      persistedRoute = .agents
      persistedDecisionID = ""
    case .decision(_, let decisionID):
      persistedRoute = .decisions
      persistedDecisionID = decisionID
    case .task:
      persistedRoute = .tasks
      persistedDecisionID = ""
    case .create:
      persistedRoute = .agents
      persistedDecisionID = ""
    }
  }

  @MainActor
  private func applyPendingSessionRouteIfNeeded() async {
    let pendingRequest = store.pendingSessionRouteRequestSnapshot
    guard let request = store.consumePendingSessionRouteRequest(forSessionID: token.sessionID) else {
      if let pendingRequest {
        HarnessMonitorUITestTrace.record(
          component: "session.window.route",
          event: "request.unmatched",
          details: [
            "window_session_id": token.sessionID,
            "selection": routeSelectionTraceLabel(for: pendingRequest.selection),
            "target_session_id": pendingRequest.selection.sessionID ?? pendingRequest.createSessionID
              ?? "nil",
            "request_id": String(store.pendingSessionRouteRequestID),
          ]
        )
      }
      return
    }
    HarnessMonitorUITestTrace.record(
      component: "session.window.route",
      event: "request.applied",
      details: [
        "window_session_id": token.sessionID,
        "selection": routeSelectionTraceLabel(for: request.selection),
        "target_session_id": request.selection.sessionID ?? request.createSessionID ?? "nil",
        "request_id": String(store.pendingSessionRouteRequestID),
      ]
    )
    if request.resetDecisionFilters {
      stateCache.decisionFilters.clear()
      persistedDecisionQuery = ""
    }
    switch request.selection {
    case .create:
      stateCache.selectCreate(routeCreateKind(for: request))
    case .decisions:
      stateCache.selectRoute(.decisions)
    case .decision(_, let decisionID):
      stateCache.selectDecision(decisionID)
    case .terminal:
      stateCache.selectRoute(.terminal)
    case .codex(_, let runID):
      stateCache.select(.codexRun(sessionID: token.sessionID, runID: runID))
    case .agent(_, let agentID):
      stateCache.selectAgent(agentID)
    case .task(_, let taskID):
      stateCache.selectTask(taskID)
    }
  }

  private func routeCreateKind(
    for request: HarnessMonitorStore.PendingSessionRouteRequest
  ) -> SessionCreateKind {
    switch request.createEntryPoint {
    case .agent, nil:
      return .agent
    }
  }

  private func routeSelectionTraceLabel(for selection: SessionRouteSelection) -> String {
    switch selection {
    case .create:
      return "create"
    case .decisions:
      return "decisions"
    case .decision(_, let decisionID):
      return "decision:\(decisionID)"
    case .terminal(_, let terminalID):
      return "terminal:\(terminalID)"
    case .codex(_, let runID):
      return "codex:\(runID)"
    case .agent(_, let agentID):
      return "agent:\(agentID)"
    case .task(_, let taskID):
      return "task:\(taskID)"
    }
  }

  private var sourceSystemImage: String {
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

  private var connectionTitle: String {
    switch store.connectionState {
    case .idle: "Idle"
    case .connecting: "Connecting"
    case .online: "Online"
    case .offline: "Offline"
    }
  }

  private func loadSnapshot() async {
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

  private func requestPrimaryContentAccessibilityFocus() {
    guard !isUnknownSession else { return }
    primaryContentAccessibilityFocused = true
    let title = summary?.displayTitle ?? "Session"
    AccessibilityNotification.Announcement("\(title) session window opened").post()
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
