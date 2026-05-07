import HarnessMonitorKit
import SwiftUI

public struct SessionWindowView: View {
  public let store: HarnessMonitorStore
  public let token: SessionWindowToken
  @State private var selectedRoute: SessionWindowRoute? = .overview
  @State private var snapshot: HarnessMonitorSessionWindowSnapshot?
  @State private var isLoading = false
  @State private var searchText = ""
  @State private var selectedDecisionID: String?

  public init(store: HarnessMonitorStore, token: SessionWindowToken) {
    self.store = store
    self.token = token
  }

  private var route: SessionWindowRoute {
    selectedRoute ?? .overview
  }

  private var summary: SessionSummary? {
    snapshot?.summary ?? store.sessionIndex.sessionSummary(for: token.sessionID)
  }

  private var matchingDecisions: [Decision] {
    store.supervisorOpenDecisions.filter { decision in
      decision.sessionID == token.sessionID && decisionMatchesSearch(decision)
    }
  }

  public var body: some View {
    NavigationSplitView {
      List(selection: $selectedRoute) {
        ForEach(SessionWindowRoute.allCases) { route in
          Label(route.title, systemImage: route.systemImage)
            .tag(Optional(route))
            .accessibilityIdentifier(HarnessMonitorAccessibility.sessionWindowRoute(route))
        }
      }
      .listStyle(.sidebar)
      .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
      .accessibilityIdentifier(HarnessMonitorAccessibility.sessionWindowSidebar)
    } detail: {
      routeContent
        .backgroundExtensionEffect()
        .navigationTitle(summary?.displayTitle ?? "Session")
        .navigationSubtitle(token.sessionID)
    }
    .toolbar { statusToolbarItem }
    .searchable(text: $searchText, placement: .toolbar, prompt: routeSearchPrompt)
    .task(id: token.sessionID) {
      await loadSnapshot()
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.sessionWindowShell)
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
          selectedDecisionID: $selectedDecisionID
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

  @ToolbarContentBuilder private var statusToolbarItem: some ToolbarContent {
    ToolbarItem(placement: .automatic) {
      Menu {
        Text("Connection: \(connectionTitle)")
        Text("Source: \(snapshot?.source.rawValue ?? "loading")")
        if let summary {
          Text("Status: \(summary.status.title)")
        }
        Text("Session: \(token.sessionID)")
      } label: {
        Label("Session Status", systemImage: statusSystemImage)
      }
      .accessibilityIdentifier(HarnessMonitorAccessibility.sessionWindowStatusMenu)
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
  @Binding var selectedDecisionID: String?

  var body: some View {
    NavigationSplitView {
      List(selection: $selectedDecisionID) {
        ForEach(decisions) { decision in
          VStack(alignment: .leading, spacing: 2) {
            Text(decision.summary)
              .lineLimit(1)
            Text(decision.ruleID)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          .tag(Optional(decision.id))
        }
      }
      .listStyle(.sidebar)
    } detail: {
      if let selected = decisions.first(where: { $0.id == selectedDecisionID }) {
        DecisionDetailSummary(decision: selected)
      } else {
        ContentUnavailableView("No Decision Selected", systemImage: "exclamationmark.bubble")
      }
    }
  }
}

private struct DecisionDetailSummary: View {
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
