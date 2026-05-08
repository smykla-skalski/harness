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
  @Environment(\.undoManager)
  private var undoManager
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
  @State private var allSessionDecisionsCache: [Decision] = []
  @State private var matchingDecisionsCache: [Decision] = []
  @State private var allSessionDecisionIDsCache: Set<String> = []
  @State private var matchingDecisionIDsCache: Set<String> = []

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

  var route: SessionWindowRoute {
    switch stateCache.selection {
    case .route(let route): route
    case .agent: .agents
    case .decision: .decisions
    case .task: .tasks
    case .create: .agents
    }
  }

  var summary: SessionSummary? {
    snapshot?.summary ?? store.sessionIndex.sessionSummary(for: token.sessionID)
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

  private var decisionsCacheTrigger: SessionDecisionFilterKey {
    SessionDecisionFilterKey(
      sessionID: token.sessionID,
      decisions: store.supervisorOpenDecisions.filter { $0.sessionID == token.sessionID },
      filters: stateCache.decisionFilters
    )
  }

  private func recomputeDecisionsCache() async {
    let all = store.supervisorOpenDecisions.filter { $0.sessionID == token.sessionID }
    let allIDs = Set(all.map(\.id))
    if all.map(\.id) != allSessionDecisionsCache.map(\.id) {
      allSessionDecisionsCache = all
    }
    if allIDs != allSessionDecisionIDsCache {
      allSessionDecisionIDsCache = allIDs
    }
    stateCache.decisionRuntime.updateFilteredDecisions(
      input: SessionDecisionFilterInput(
        sessionID: token.sessionID,
        decisions: all,
        filters: stateCache.decisionFilters
      )
    )
    await stateCache.decisionRuntime.waitForDecisionFilterIdle()
    guard !Task.isCancelled else { return }
    let matching = stateCache.decisionRuntime.filteredDecisions(from: all)
    let matchingIDs = Set(matching.map(\.id))
    if matching.map(\.id) != matchingDecisionsCache.map(\.id) {
      matchingDecisionsCache = matching
    }
    if matchingIDs != matchingDecisionIDsCache {
      matchingDecisionIDsCache = matchingIDs
    }
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
    Group {
      if isUnknownSession {
        unknownSessionContent
      } else {
        sessionSurface
      }
    }
    .toolbar {
      SessionWindowToolbar(
        snapshot: snapshot,
        connectionTitle: connectionTitle,
        statusSystemImage: statusSystemImage,
        sessionID: token.sessionID,
        focusMode: $focusMode
      )
    }
    .sessionTitleBlurChrome(
      status: summary?.status ?? .awaitingLeader,
      isStale: snapshot == nil
    )
    .onChange(of: focusMode) { _, _ in
      reconcileInspectorVisibility(
        visibleBinding: $inspectorVisible,
        preferredBinding: $inspectorPreferred
      )
    }
    .task(id: token.sessionID) {
      hydrateSelectionFromPersistedStorage()
      hydrateDecisionFiltersFromPersistedStorage()
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
    .task(id: decisionsCacheTrigger) {
      await recomputeDecisionsCache()
    }
    .onChange(of: stateCache.selection) { _, newSelection in
      syncPersistedStorage(from: newSelection)
      reconcileInspectorVisibility(
        visibleBinding: $inspectorVisible,
        preferredBinding: $inspectorPreferred
      )
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

  private var navigationCommand: SessionNavigationCommand {
    let cache = stateCache
    return SessionNavigationCommand(
      sessionID: token.sessionID,
      canGoBack: stateCache.navigationHistory.canGoBack,
      canGoForward: stateCache.navigationHistory.canGoForward,
      goBack: { cache.navigateBack() },
      goForward: { cache.navigateForward() }
    )
  }

  private var attentionFocus: SessionAttentionFocus {
    SessionAttentionFocus(
      sessionID: token.sessionID,
      pendingDecisionCount: matchingDecisions.count
    )
  }

  private var inspectorCommand: SessionInspectorCommand {
    let visibleBinding = $inspectorVisible
    let preferredBinding = $inspectorPreferred
    return SessionInspectorCommand(
      sessionID: token.sessionID,
      isVisible: visibleBinding.wrappedValue && canPresentInspector,
      toggle: {
        setInspectorPreference(
          !preferredBinding.wrappedValue,
          visibleBinding: visibleBinding,
          preferredBinding: preferredBinding
        )
      }
    )
  }

  private var decisionCommand: SessionDecisionCommand {
    SessionDecisionCommandFactory.make(
      store: store,
      state: stateCache,
      visibleDecisions: matchingDecisions,
      undoManager: undoManager
    )
  }

  private var createContext: SessionCreateContext {
    let cache = stateCache
    return SessionCreateContext(
      sessionID: token.sessionID,
      primaryKind: primaryCreateKind,
      createAgent: { cache.selectCreate(.agent) },
      createTask: { cache.selectCreate(.task) },
      createDecision: { cache.selectCreate(.decision) }
    )
  }

  private var primaryCreateKind: SessionCreateKind {
    switch stateCache.selection {
    case .agent: .agent
    case .task: .task
    case .decision: .decision
    case .create(let draft): draft.kind
    case .route(let route):
      switch route {
      case .tasks: .task
      case .decisions: .decision
      case .agents, .overview, .timeline, .terminal: .agent
      }
    }
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

  private func syncPersistedStorage(from selection: SessionSelection) {
    switch selection {
    case .route(let route):
      persistedRoute = route
      persistedDecisionID = ""
    case .agent:
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

  private var statusSystemImage: String {
    guard let source = snapshot?.source else {
      return "arrow.trianglehead.2.clockwise"
    }
    return source == .live ? "bolt.horizontal.circle" : "externaldrive"
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
    isLoading = true
    await store.bootstrapIfNeeded()
    snapshot = await store.sessionWindowSnapshot(sessionID: token.sessionID)
    didLoadSnapshot = true
    isLoading = false
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
