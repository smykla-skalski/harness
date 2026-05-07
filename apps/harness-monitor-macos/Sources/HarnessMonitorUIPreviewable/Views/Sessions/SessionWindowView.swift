import AppKit
import HarnessMonitorKit
import SwiftUI

public struct SessionWindowView: View {
  public let store: HarnessMonitorStore
  public let token: SessionWindowToken
  @State private var stateCache: SessionWindowStateCache
  @SceneStorage("session.route")
  private var persistedRoute: SessionWindowRoute = .overview
  @SceneStorage("session.decisionID")
  private var persistedDecisionID: String = ""
  @SceneStorage("session.searchText")
  private var searchText: String = ""
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

  private var matchingDecisions: [Decision] {
    store.supervisorOpenDecisions.filter { decision in
      decision.sessionID == token.sessionID && decisionMatchesSearch(decision)
    }
  }

  private var selectedDecision: Decision? {
    guard let decisionID = stateCache.selection.decisionID else { return nil }
    return matchingDecisions.first { $0.id == decisionID }
  }

  public var body: some View {
    NavigationSplitView(columnVisibility: columnVisibilityBinding) {
      SessionSidebar(
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
    .searchable(text: $searchText, placement: .toolbar, prompt: routeSearchPrompt)
    .onChange(of: focusMode) { _, newValue in
      if newValue {
        inspectorVisible = false
      }
    }
    .task(id: token.sessionID) {
      hydrateSelectionFromPersistedStorage()
      await loadSnapshot()
    }
    .onChange(of: stateCache.selection) { _, newSelection in
      syncPersistedStorage(from: newSelection)
    }
    .focusedSceneValue(\.sessionNavigation, navigationCommand)
    .focusedSceneValue(\.sessionAttention, attentionFocus)
    .focusedSceneValue(\.sessionInspector, inspectorCommand)
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
      isVisible: inspectorVisible,
      toggle: {
        let next = !binding.wrappedValue
        SessionInspectorAnnouncer.announce(visible: next)
        binding.wrappedValue = next
      }
    )
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
    HStack(spacing: 0) {
      detailFocus
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .backgroundExtensionEffect()
      if inspectorVisible {
        SessionInspectorDivider(
          width: $inspectorWidth,
          minWidth: 220,
          maxWidth: 420
        )
        SessionWindowInspector(
          selection: stateCache.selection,
          selectedDecision: selectedDecision,
          visible: $inspectorVisible
        )
        .frame(width: max(220, min(inspectorWidth, 420)))
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
        DecisionDetailSummary(decision: selectedDecision)
      } else {
        ContentUnavailableView(
          "No Decision Selected",
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
      ContentUnavailableView(
        "Create \(draft.kind.rawValue.capitalized)",
        systemImage: "plus.circle",
        description: Text("Form lands in a later chunk.")
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

  private var routeSearchPrompt: Text {
    switch route {
    case .decisions: Text("Search decisions")
    case .timeline: Text("Search timeline")
    case .overview, .agents, .tasks, .terminal: Text("Search")
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

  private func decisionMatchesSearch(_ decision: Decision) -> Bool {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return true }
    return decision.summary.localizedCaseInsensitiveContains(query)
      || decision.ruleID.localizedCaseInsensitiveContains(query)
      || (decision.agentID?.localizedCaseInsensitiveContains(query) ?? false)
      || (decision.taskID?.localizedCaseInsensitiveContains(query) ?? false)
  }

  private func agentTui(for agent: AgentRegistration) -> AgentTuiSnapshot? {
    store.selectedAgentTuis.first { tui in
      tui.sessionId == token.sessionID
        && (tui.sessionAgentID == agent.agentId
          || tui.managedAgentID == agent.managedAgentID
          || tui.tuiId == agent.managedAgentID)
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
