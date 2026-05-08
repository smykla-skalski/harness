import AppKit
import HarnessMonitorKit
import SwiftUI

public struct SessionWindowView: View {
  public let store: HarnessMonitorStore
  public let token: SessionWindowToken
  @State private var stateCache: SessionWindowStateCache
  @Environment(\.undoManager)
  private var undoManager
  @SceneStorage("session.route")
  private var persistedRoute: SessionWindowRoute = .overview
  @SceneStorage("session.decisionID")
  private var persistedDecisionID: String = ""
  @SceneStorage("session.decisionFilters.query")
  private var persistedDecisionQuery = ""
  @SceneStorage("session.focusMode")
  private var focusMode = false
  @SceneStorage("session.inspector.visible")
  private var inspectorVisible = false
  @SceneStorage("session.inspector.width")
  private var inspectorWidth = 280.0
  @SceneStorage("session.sidebarWidth")
  private var sidebarWidth = 220.0
  @SceneStorage("session.columnVisibility")
  private var columnVisibilityRaw = "automatic"
  @State private var snapshot: HarnessMonitorSessionWindowSnapshot?
  @State private var isLoading = false
  @State private var detailColumnWidth: CGFloat = 0

  public init(store: HarnessMonitorStore, token: SessionWindowToken) {
    self.store = store
    self.token = token
    _stateCache = State(wrappedValue: SessionWindowStateCache(sessionID: token.sessionID))
  }

  private var route: SessionWindowRoute {
    switch stateCache.selection {
    case .route(let route): route
    case .agent: .agents
    case .decision: .decisions
    case .task: .tasks
    case .create: .agents
    }
  }

  private var summary: SessionSummary? {
    snapshot?.summary ?? store.sessionIndex.sessionSummary(for: token.sessionID)
  }

  private var allSessionDecisions: [Decision] {
    store.supervisorOpenDecisions.filter { $0.sessionID == token.sessionID }
  }

  private var matchingDecisions: [Decision] {
    allSessionDecisions.filter { stateCache.decisionFilters.matches($0) }
  }

  private var selectedDecision: Decision? {
    stateCache.selectedDecision(in: allSessionDecisions)
  }

  private var selectedDecisionVisibility: SessionSelectedDecisionVisibility {
    stateCache.selectedDecisionVisibility(
      allDecisionIDs: Set(allSessionDecisions.map(\.id)),
      visibleDecisionIDs: Set(matchingDecisions.map(\.id))
    )
  }

  private var selectedDecisionHiddenByFilters: Bool {
    selectedDecisionVisibility == .hidden
  }

  private var inspectorContextDecision: Decision? {
    guard case .decision = stateCache.selection else {
      return nil
    }
    return selectedDecision
  }

  private var canPresentInspector: Bool {
    guard !focusMode, inspectorContextDecision != nil else {
      return false
    }
    guard detailColumnWidth > 0 else {
      return false
    }
    return stateCache.decisionRuntime.allowsInspector(width: detailColumnWidth)
  }

  public var body: some View {
    NavigationSplitView(columnVisibility: columnVisibilityBinding) {
      SessionSidebar(
        store: store,
        snapshot: snapshot,
        decisions: matchingDecisions,
        state: stateCache
      )
      .navigationSplitViewColumnWidth(min: 190, ideal: sidebarWidth, max: 360)
    } content: {
      contentColumn
        .navigationSplitViewColumnWidth(min: 280, ideal: 360, max: 520)
        .navigationTitle(summary?.displayTitle ?? "Session")
        .navigationSubtitle(token.sessionID)
    } detail: {
      detailColumn
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
      reconcileInspectorVisibility(binding: $inspectorVisible)
    }
    .task(id: token.sessionID) {
      hydrateSelectionFromPersistedStorage()
      hydrateDecisionFiltersFromPersistedStorage()
      reconcileInspectorVisibility(binding: $inspectorVisible, announce: false)
      await loadSnapshot()
      reconcileInspectorVisibility(binding: $inspectorVisible, announce: false)
    }
    .onChange(of: stateCache.selection) { _, newSelection in
      syncPersistedStorage(from: newSelection)
      reconcileInspectorVisibility(binding: $inspectorVisible)
    }
    .onChange(of: stateCache.decisionFilters.query) { _, newValue in
      guard persistedDecisionQuery != newValue else { return }
      persistedDecisionQuery = newValue
    }
    .onChange(of: allSessionDecisions.map(\.id)) { _, _ in
      reconcileInspectorVisibility(binding: $inspectorVisible)
    }
    .focusedSceneValue(\.sessionNavigation, navigationCommand)
    .focusedSceneValue(\.sessionAttention, attentionFocus)
    .focusedSceneValue(\.sessionInspector, canPresentInspector ? inspectorCommand : nil)
    .focusedSceneValue(\.sessionDecisionCommands, decisionCommand)
    .focusedSceneValue(\.sessionCreateContext, createContext)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.sessionWindowShell)
  }

  private var columnVisibilityBinding: Binding<NavigationSplitViewVisibility> {
    Binding(
      get: {
        focusMode
          ? .detailOnly
          : SessionColumnVisibilityCodec.decode(columnVisibilityRaw)
      },
      set: { newValue in
        columnVisibilityRaw = SessionColumnVisibilityCodec.encode(newValue)
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
    let binding = $inspectorVisible
    return SessionInspectorCommand(
      sessionID: token.sessionID,
      isVisible: binding.wrappedValue && canPresentInspector,
      toggle: {
        let next = !binding.wrappedValue
        setInspectorVisibility(next, binding: binding)
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

  @ViewBuilder private var contentColumn: some View {
    if isLoading && snapshot == nil {
      ProgressView("Loading session")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if let snapshot {
      switch route {
      case .overview: SessionWindowOverview(snapshot: snapshot)
      case .agents: SessionWindowAgentsList(detail: snapshot.detail)
      case .tasks: SessionWindowTasksList(detail: snapshot.detail)
      case .decisions:
        SessionWindowDecisionsList(decisions: matchingDecisions, state: stateCache)
      case .timeline:
        MonitorTimelineSection(
          host: .session(snapshot.summary.sessionId),
          timeline: snapshot.timeline,
          timelineWindow: snapshot.timelineWindow,
          decisions: matchingDecisions,
          isTimelineLoading: isLoading,
          store: store
        )
        .padding(24)
      case .terminal: SessionWindowRunsList(detail: snapshot.detail)
      }
    } else {
      ContentUnavailableView(
        "Session Not Available",
        systemImage: "questionmark.folder",
        description: Text(token.sessionID)
      )
    }
  }

  @ViewBuilder private var detailColumn: some View {
    GeometryReader { geometry in
      let inspectorAllowed = inspectorContextDecision != nil
        && !focusMode
        && stateCache.decisionRuntime.allowsInspector(width: geometry.size.width)
      HStack(spacing: 0) {
        detailFocus
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .backgroundExtensionEffect()
        if inspectorVisible, inspectorAllowed, let inspectorDecision = inspectorContextDecision {
          SessionInspectorDivider(
            width: $inspectorWidth,
            minWidth: 220,
            maxWidth: 420
          )
          SessionWindowInspector(
            decision: inspectorDecision,
            isFilteredOut: selectedDecisionHiddenByFilters,
            decisionFilters: stateCache.decisionFilters,
            decisionRuntime: stateCache.decisionRuntime,
            visible: $inspectorVisible
          )
          .frame(width: max(220, min(inspectorWidth, 420)))
        }
      }
      .onAppear {
        updateDetailColumnWidth(
          geometry.size.width,
          binding: $inspectorVisible,
          announce: false
        )
      }
      .onChange(of: geometry.size.width) { _, newWidth in
        updateDetailColumnWidth(newWidth, binding: $inspectorVisible)
      }
    }
  }

  @ViewBuilder private var detailFocus: some View {
    switch stateCache.selection {
    case .agent(_, let agentID):
      if let agent = snapshot?.detail?.agents.first(where: { $0.agentId == agentID }) {
        SessionAgentDetailSection(
          store: store,
          sessionID: token.sessionID,
          agent: agent,
          tui: agentTui(for: agent)
        )
      } else {
        ContentUnavailableView(
          "Agent \(agentID)",
          systemImage: "person.crop.circle",
          description: Text("Agent detail is not available.")
        )
      }
    case .decision:
      if let selectedDecision {
        VStack(alignment: .leading, spacing: 12) {
          if selectedDecisionHiddenByFilters {
            SessionFilteredDecisionNotice(filters: stateCache.decisionFilters)
          }
          SessionDecisionDetailPane(
            decision: selectedDecision,
            runtime: stateCache.decisionRuntime
          )
        }
      } else {
        ContentUnavailableView(
          selectedDecisionVisibility == .missing
            ? "Decision Not Available"
            : "No Decision Selected",
          systemImage: "exclamationmark.bubble"
        )
      }
    case .task(_, let taskID):
      ContentUnavailableView(
        "Task \(taskID)",
        systemImage: "checklist",
        description: Text("Task detail lands in a later chunk.")
      )
    case .create(let draft):
      SessionWindowCreateForm(
        store: store,
        state: stateCache,
        draft: draft
      )
    case .route:
      ContentUnavailableView(
        "Select an Item",
        systemImage: "sidebar.right",
        description: Text("Pick an agent, decision, or task in the sidebar.")
      )
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
    isLoading = false
  }

  private func agentTui(for agent: AgentRegistration) -> AgentTuiSnapshot? {
    store.selectedAgentTuis.first { tui in
      tui.sessionId == token.sessionID
        && (tui.sessionAgentID == agent.agentId
          || tui.managedAgentID == agent.managedAgentID
          || tui.tuiId == agent.managedAgentID)
    }
  }

  private func updateDetailColumnWidth(
    _ width: CGFloat,
    binding: Binding<Bool>,
    announce: Bool = true
  ) {
    guard abs(detailColumnWidth - width) > 0.5 else { return }
    detailColumnWidth = width
    reconcileInspectorVisibility(binding: binding, announce: announce)
  }

  private func reconcileInspectorVisibility(
    binding: Binding<Bool>,
    announce: Bool = true
  ) {
    guard binding.wrappedValue, !canPresentInspector else { return }
    setInspectorVisibility(false, binding: binding, announce: announce)
  }

  private func setInspectorVisibility(
    _ visible: Bool,
    binding: Binding<Bool>,
    announce: Bool = true
  ) {
    guard binding.wrappedValue != visible else { return }
    if visible {
      guard canPresentInspector else { return }
    }
    binding.wrappedValue = visible
    if announce {
      SessionInspectorAnnouncer.announce(visible: visible)
    }
  }
}

private struct SessionInspectorDivider: View {
  @Binding var width: Double
  let minWidth: Double
  let maxWidth: Double
  @State private var dragStartWidth: Double?

  var body: some View {
    Rectangle()
      .fill(.separator)
      .frame(width: 1)
      .overlay(alignment: .center) {
        Color.clear
          .frame(width: 8)
          .contentShape(Rectangle())
          .onHover { hovering in
            if hovering {
              NSCursor.resizeLeftRight.push()
            } else {
              NSCursor.pop()
            }
          }
          .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
              .onChanged { value in
                if dragStartWidth == nil { dragStartWidth = width }
                let delta = value.translation.width
                let next = (dragStartWidth ?? width) - delta
                width = max(minWidth, min(next, maxWidth))
              }
              .onEnded { _ in dragStartWidth = nil }
          )
      }
      .accessibilityHidden(true)
  }
}
