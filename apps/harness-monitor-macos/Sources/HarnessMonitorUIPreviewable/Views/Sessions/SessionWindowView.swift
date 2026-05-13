import HarnessMonitorKit
import SwiftUI

public struct SessionWindowView: View {
  public let store: HarnessMonitorStore
  public let token: SessionWindowToken
  @State private var stateCacheStorage: SessionWindowStateCache
  @Environment(\.dismiss)
  var dismiss
  @Environment(\.openWindow)
  var openWindow
  @Environment(\.accessibilityReduceMotion)
  var reduceMotion: Bool
  @SceneStorage("session.route")
  var persistedRoute: SessionWindowRoute = .overview
  @SceneStorage("session.decisionID")
  var persistedDecisionID: String = ""
  @SceneStorage("session.decisionFilters.query")
  var persistedDecisionQuery = ""
  @SceneStorage("session.decision.detail-tab")
  private var persistedDecisionDetailTabRawStorage = DecisionDetailTab.context.rawValue
  @SceneStorage("session.focusMode")
  private var focusModeStorage = false
  @SceneStorage("session.inspector.visible")
  private var inspectorVisibleStorage = false
  @SceneStorage("session.inspector.preferred")
  private var inspectorPreferredStorage = false
  @SceneStorage("session.inspector.width")
  private var inspectorWidthStorage = 280.0
  @SceneStorage("session.sidebarWidth")
  private var sidebarWidthStorage = 200.0
  @SceneStorage("session.content-detail.width")
  private var contentColumnWidthStorage = SessionContentDetailSplitLayout.defaultContentWidth
  @AccessibilityFocusState private var primaryContentAccessibilityFocused: Bool
  @AppStorage(HarnessMonitorMCPSettingsDefaults.registryHostEnabledKey)
  var mcpRegistryHostEnabled = HarnessMonitorMCPSettingsDefaults
    .registryHostEnabledDefault
  @State private var snapshotStorage: HarnessMonitorSessionWindowSnapshot?
  @State private var isLoadingStorage = false
  @State private var didLoadSnapshotStorage = false
  @State private var detailColumnWidthStorage: CGFloat = 0
  @State private var liveInspectorWidthStorage: Double?
  @State private var liveContentColumnWidthStorage: Double?
  @State private var perfContentDividerWidthStorage: Double?
  @State private var decisionCacheStorage = SessionWindowDecisionCacheStorage()
  @State private var currentModifiers: EventModifiers = []
  @State private var startupSearchParticipationEnabledStorage =
    HarnessMonitorUITestEnvironment.isEnabled

  public init(store: HarnessMonitorStore, token: SessionWindowToken) {
    self.store = store
    self.token = token
    _stateCacheStorage = State(wrappedValue: SessionWindowStateCache(sessionID: token.sessionID))
  }
  var stateCache: SessionWindowStateCache {
    stateCacheStorage
  }
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

  var focusMode: Bool {
    get { focusModeStorage }
    nonmutating set { focusModeStorage = newValue }
  }

  var focusModeBinding: Binding<Bool> {
    Binding(
      get: { focusModeStorage },
      set: { if focusModeStorage != $0 { focusModeStorage = $0 } }
    )
  }

  var inspectorVisible: Bool {
    get { inspectorVisibleStorage }
    nonmutating set { inspectorVisibleStorage = newValue }
  }

  var inspectorVisibleBinding: Binding<Bool> {
    Binding(
      get: { inspectorVisibleStorage },
      set: { if inspectorVisibleStorage != $0 { inspectorVisibleStorage = $0 } }
    )
  }

  var inspectorPreferred: Bool {
    get { inspectorPreferredStorage }
    nonmutating set { inspectorPreferredStorage = newValue }
  }

  var inspectorPreferredBinding: Binding<Bool> {
    Binding(
      get: { inspectorPreferredStorage },
      set: { if inspectorPreferredStorage != $0 { inspectorPreferredStorage = $0 } }
    )
  }

  var storedInspectorWidth: Double {
    get { inspectorWidthStorage }
    nonmutating set { inspectorWidthStorage = newValue }
  }

  var liveInspectorWidthDraft: Double? {
    get { liveInspectorWidthStorage }
    nonmutating set { liveInspectorWidthStorage = newValue }
  }

  var storedContentColumnWidth: Double {
    get { contentColumnWidthStorage }
    nonmutating set { contentColumnWidthStorage = newValue }
  }

  var liveContentColumnWidthDraft: Double? {
    get { liveContentColumnWidthStorage }
    nonmutating set { liveContentColumnWidthStorage = newValue }
  }

  var perfContentDividerWidth: Double? {
    get { perfContentDividerWidthStorage }
    nonmutating set { perfContentDividerWidthStorage = newValue }
  }

  var perfContentDividerWidthBinding: Binding<Double?> {
    Binding(
      get: { perfContentDividerWidth },
      set: { perfContentDividerWidth = $0 }
    )
  }

  var sidebarWidth: Double {
    get { sidebarWidthStorage }
    nonmutating set { sidebarWidthStorage = newValue }
  }

  var presentedModifiers: EventModifiers {
    currentModifiers
  }

  var isStartupSearchParticipationEnabled: Bool {
    get { startupSearchParticipationEnabledStorage }
    nonmutating set { startupSearchParticipationEnabledStorage = newValue }
  }

  func enableStartupSearchParticipation() {
    guard !isStartupSearchParticipationEnabled else { return }
    isStartupSearchParticipationEnabled = true
  }

  var decisionDetailTab: DecisionDetailTab {
    get { DecisionDetailTab(rawValue: persistedDecisionDetailTabRawStorage) ?? .context }
    nonmutating set { persistedDecisionDetailTabRawStorage = newValue.rawValue }
  }

  var decisionDetailTabBinding: Binding<DecisionDetailTab> {
    Binding(
      get: { decisionDetailTab },
      set: { if decisionDetailTab != $0 { decisionDetailTab = $0 } }
    )
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

  public var body: some View {
    ZStack {
      bodyContent
      sessionSearchHost
    }
    .toolbar { sessionToolbar }
    .background {
      sessionWindowBackgroundAnchors(currentModifiers: $currentModifiers)
    }
  }

  private var bodyContent: some View {
    sessionWindowFocusedValues(
      sessionWindowDecisionFilterPersistence(
        sessionWindowSelectionObservers(
          sessionWindowLifecycleModifiers(sessionWindowSurface)
        )
      )
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .accessibilityElement(children: .contain)
    .accessibilityFocused($primaryContentAccessibilityFocused)
    .accessibilityIdentifier(HarnessMonitorAccessibility.sessionWindowShell)
  }

  @ViewBuilder private var sessionWindowSurface: some View {
    if isUnknownSession {
      unknownSessionContent
    } else {
      sessionSurface
    }
  }

  private func sessionWindowSelectionObservers<Content: View>(
    _ content: Content
  ) -> some View {
    content
      .onChange(of: stateCache.selection) { _, newSelection in
        syncPersistedStorage(from: newSelection)
        reconcileInspectorVisibility(
          visibleBinding: inspectorVisibleBinding,
          preferredBinding: inspectorPreferredBinding
        )
        detailRenderedSelection = newSelection
        contentRenderedRoute = route(for: newSelection)
        if case .create(let draft) = newSelection, draft.kind == .agent {
          commitContentColumnWidth(SessionContentDetailSplitLayout.defaultContentWidth)
        }
      }
      .onChange(of: stateCache.sectionState.decisionID) { _, newDecisionID in
        guard case .route(.decisions) = stateCache.selection else { return }
        let storedDecisionID = newDecisionID ?? ""
        guard persistedDecisionID != storedDecisionID else { return }
        persistedDecisionID = storedDecisionID
      }
      .onChange(of: renderedRoute) { _, newRoute in
        guard newRoute.layoutStyle == .sidebarDetail else { return }
        detailColumnWidth = 0
      }
      .onChange(of: allSessionDecisions.map(\.id)) { _, _ in
        reconcileInspectorVisibility(
          visibleBinding: inspectorVisibleBinding,
          preferredBinding: inspectorPreferredBinding
        )
      }
  }

  private func sessionWindowDecisionFilterPersistence<Content: View>(
    _ content: Content
  ) -> some View {
    content
      .onChange(of: stateCache.decisionFilters.query) { _, newValue in
        guard persistedDecisionQuery != newValue else { return }
        persistedDecisionQuery = newValue
      }
  }

  @MainActor
  func applyPendingSessionRouteIfNeeded() async {
    let pendingRequest = store.pendingSessionRouteRequestSnapshot
    guard let request = store.consumePendingSessionRouteRequest(forSessionID: token.sessionID)
    else {
      if let pendingRequest {
        HarnessMonitorUITestTrace.record(
          component: "session.window.route",
          event: "request.unmatched",
          details: [
            "window_session_id": token.sessionID,
            "selection": routeSelectionTraceLabel(for: pendingRequest.selection),
            "target_session_id": pendingRequest.selection.sessionID ?? pendingRequest
              .createSessionID
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
      clearPersistedDecisionQueryIfNeeded()
    }
    switch request.selection {
    case .create:
      stateCache.selectCreate(routeCreateKind(for: request))
    case .decisions:
      stateCache.selectRoute(.decisions)
    case .decision(_, let decisionID):
      stateCache.selectDecision(decisionID)
    case .terminal(_, let terminalID):
      stateCache.selectAgent(terminalID)
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
    case .task:
      return .task
    case .decision:
      return .decision
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
      return "terminal->agent:\(terminalID)"
    case .codex(_, let runID):
      return "codex:\(runID)"
    case .agent(_, let agentID):
      return "agent:\(agentID)"
    case .task(_, let taskID):
      return "task:\(taskID)"
    }
  }

  func requestPrimaryContentAccessibilityFocus() {
    guard !isUnknownSession else { return }
    primaryContentAccessibilityFocused = true
    let title = summary?.displayTitle ?? "Session"
    AccessibilityNotification.Announcement("\(title) session window opened").post()
  }
}
