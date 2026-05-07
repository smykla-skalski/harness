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
  @State private var snapshot: HarnessMonitorSessionWindowSnapshot?
  @State private var isLoading = false

  public init(store: HarnessMonitorStore, token: SessionWindowToken) {
    self.store = store
    self.token = token
    _stateCache = State(wrappedValue: SessionWindowStateCache(sessionID: token.sessionID))
  }

  private var route: SessionWindowRoute {
    switch stateCache.selection {
    case .route(let route):
      route
    case .agent:
      .agents
    case .decision:
      .decisions
    case .task:
      .tasks
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
    NavigationSplitView {
      SessionSidebar(
        snapshot: snapshot,
        decisions: matchingDecisions,
        state: stateCache
      )
      .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
    } detail: {
      HStack(spacing: 0) {
        routeContent
          .backgroundExtensionEffect()
          .navigationTitle(summary?.displayTitle ?? "Session")
          .navigationSubtitle(token.sessionID)
        if inspectorVisible {
          Divider()
          SessionWindowInspector(
            selection: stateCache.selection,
            selectedDecision: selectedDecision
          )
          .frame(width: max(220, min(inspectorWidth, 420)))
        }
      }
    }
    .toolbar {
      SessionWindowToolbar(
        snapshot: snapshot,
        connectionTitle: connectionTitle,
        statusSystemImage: statusSystemImage,
        sessionID: token.sessionID,
        focusMode: $focusMode,
        inspectorVisible: $inspectorVisible
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
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.sessionWindowShell)
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
    }
  }

  @ViewBuilder private var routeContent: some View {
    if isLoading && snapshot == nil {
      ProgressView("Loading session")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if let snapshot {
      switch route {
      case .overview:
        SessionWindowOverview(snapshot: snapshot)
      case .agents:
        SessionWindowAgents(detail: snapshot.detail)
      case .tasks:
        SessionWindowTasks(detail: snapshot.detail)
      case .decisions:
        SessionWindowDecisions(
          decisions: matchingDecisions,
          state: stateCache
        )
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
      case .terminal:
        SessionWindowRuns(detail: snapshot.detail)
      }
    } else {
      ContentUnavailableView(
        "Session Not Available",
        systemImage: "questionmark.folder",
        description: Text(token.sessionID)
      )
    }
  }

  private var routeSearchPrompt: Text {
    switch route {
    case .decisions:
      Text("Search decisions")
    case .timeline:
      Text("Search timeline")
    case .overview, .agents, .tasks, .terminal:
      Text("Search")
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
    case .idle:
      "Idle"
    case .connecting:
      "Connecting"
    case .online:
      "Online"
    case .offline:
      "Offline"
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
    guard !query.isEmpty else {
      return true
    }
    return decision.summary.localizedCaseInsensitiveContains(query)
      || decision.ruleID.localizedCaseInsensitiveContains(query)
      || (decision.agentID?.localizedCaseInsensitiveContains(query) ?? false)
      || (decision.taskID?.localizedCaseInsensitiveContains(query) ?? false)
  }
}

private struct SessionWindowOverview: View {
  let snapshot: HarnessMonitorSessionWindowSnapshot

  var body: some View {
    HarnessMonitorColumnScrollView(
      horizontalPadding: 24,
      verticalPadding: 24,
      constrainContentWidth: true,
      readableWidth: false,
      topScrollEdgeEffect: .soft,
      scrollSurfaceIdentifier: HarnessMonitorAccessibility.sessionCockpitScrollView,
      scrollSurfaceLabel: "Session overview"
    ) {
      VStack(alignment: .leading, spacing: 16) {
        Text(snapshot.summary.displayTitle)
          .scaledFont(.system(.title2, design: .rounded, weight: .semibold))
        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
          metric("Status", snapshot.summary.status.title)
          metric("Project", snapshot.summary.projectName)
          metric("Worktree", snapshot.summary.worktreeDisplayName)
          metric("Agents", "\(agentCount)")
          metric("Open tasks", "\(snapshot.summary.metrics.openTaskCount)")
          metric("Source", snapshot.source.rawValue)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func metric(_ title: String, _ value: String) -> some View {
    GridRow {
      Text(title)
        .foregroundStyle(.secondary)
      Text(value)
        .textSelection(.enabled)
    }
  }

  private var agentCount: Int {
    snapshot.detail?.agents.count ?? snapshot.summary.metrics.agentCount
  }
}

private struct SessionWindowAgents: View {
  let detail: SessionDetail?

  var body: some View {
    sessionListSurface("Agents") {
      if let agents = detail?.agents, !agents.isEmpty {
        ForEach(agents) { agent in
          Label {
            VStack(alignment: .leading, spacing: 2) {
              Text(agent.name)
              Text("\(agent.role.title) - \(agent.runtime) - \(agent.agentId)")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          } icon: {
            Image(systemName: "person.crop.circle")
          }
        }
      } else {
        ContentUnavailableView("No Agents", systemImage: "person.3")
      }
    }
  }
}

private struct SessionWindowTasks: View {
  let detail: SessionDetail?

  var body: some View {
    sessionListSurface("Tasks") {
      if let tasks = detail?.tasks, !tasks.isEmpty {
        ForEach(tasks) { task in
          Label {
            VStack(alignment: .leading, spacing: 2) {
              Text(task.title)
              Text("\(task.status.title) - \(task.severity.title)")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          } icon: {
            Image(systemName: "checklist")
          }
        }
      } else {
        ContentUnavailableView("No Tasks", systemImage: "checklist")
      }
    }
  }
}

private struct SessionWindowDecisions: View {
  let decisions: [Decision]
  @Bindable var state: SessionWindowStateCache

  var body: some View {
    NavigationSplitView {
      List(selection: decisionBinding) {
        ForEach(decisions) { decision in
          VStack(alignment: .leading, spacing: 2) {
            Text(decision.summary)
              .lineLimit(1)
            Text(decision.ruleID)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          .tag(decision.id)
        }
      }
      .listStyle(.sidebar)
    } detail: {
      if let selected = decisions.first(where: { $0.id == state.selection.decisionID }) {
        DecisionDetailSummary(decision: selected)
      } else {
        ContentUnavailableView("No Decision Selected", systemImage: "exclamationmark.bubble")
      }
    }
  }

  private var decisionBinding: Binding<String?> {
    Binding(
      get: { state.selection.decisionID },
      set: { decisionID in
        guard let decisionID else { return }
        state.selectDecision(decisionID)
      }
    )
  }
}

struct DecisionDetailSummary: View {
  let decision: Decision

  var body: some View {
    Form {
      LabeledContent("Summary", value: decision.summary)
      LabeledContent("Rule", value: decision.ruleID)
      LabeledContent("Severity", value: decision.severityRaw)
      if let agentID = decision.agentID {
        LabeledContent("Agent", value: agentID)
      }
      if let taskID = decision.taskID {
        LabeledContent("Task", value: taskID)
      }
    }
    .formStyle(.grouped)
    .padding(24)
  }
}

private struct SessionWindowRuns: View {
  let detail: SessionDetail?

  var body: some View {
    sessionListSurface("Terminal/Runs") {
      if let agents = detail?.agents, !agents.isEmpty {
        ForEach(agents) { agent in
          Label(agent.name, systemImage: "terminal")
        }
      } else {
        ContentUnavailableView("No Terminal Sessions", systemImage: "terminal")
      }
    }
  }
}

@MainActor
private func sessionListSurface<Content: View>(
  _ title: String,
  @ViewBuilder content: () -> Content
) -> some View {
  List {
    Section(title) {
      content()
    }
  }
  .listStyle(.inset)
}
