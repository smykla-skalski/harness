import HarnessMonitorKit
import SwiftUI

struct SessionSidebar: View {
  let snapshot: HarnessMonitorSessionWindowSnapshot?
  let decisions: [Decision]
  @Bindable var state: SessionWindowStateCache

  var body: some View {
    List(selection: selectionBinding) {
      routeSection
      agentsSection
      tasksSection
      decisionsSection
    }
    .listStyle(.sidebar)
    .accessibilityIdentifier(HarnessMonitorAccessibility.sessionWindowSidebar)
  }

  private var selectionBinding: Binding<SessionSelection?> {
    Binding(
      get: { state.selection },
      set: { state.selection = $0 ?? .route(.overview) }
    )
  }

  private var routeSection: some View {
    Section("Routes") {
      ForEach([SessionWindowRoute.overview, .timeline, .terminal]) { route in
        Label(route.title, systemImage: route.systemImage)
          .tag(SessionSelection.route(route))
          .accessibilityIdentifier(HarnessMonitorAccessibility.sessionWindowRoute(route))
      }
    }
  }

  @ViewBuilder private var agentsSection: some View {
    Section("Agents") {
      ForEach(snapshot?.detail?.agents ?? []) { agent in
        SessionSidebarRow(
          title: agent.name,
          subtitle: agent.runtime,
          systemImage: "person.crop.circle",
          badge: agent.status.title
        )
        .tag(SessionSelection.agent(sessionID: state.sessionID, agentID: agent.agentId))
      }
      if (snapshot?.detail?.agents ?? []).isEmpty {
        Text("No agents")
          .foregroundStyle(.secondary)
      }
    }
  }

  @ViewBuilder private var tasksSection: some View {
    Section("Tasks") {
      ForEach(snapshot?.detail?.tasks ?? []) { task in
        SessionSidebarRow(
          title: task.title,
          subtitle: task.status.title,
          systemImage: "checklist",
          badge: task.severity.title
        )
        .tag(SessionSelection.task(sessionID: state.sessionID, taskID: task.taskId))
      }
      if (snapshot?.detail?.tasks ?? []).isEmpty {
        Text("No tasks")
          .foregroundStyle(.secondary)
      }
    }
  }

  @ViewBuilder private var decisionsSection: some View {
    Section {
      ForEach(decisions) { decision in
        SessionSidebarRow(
          title: decision.summary,
          subtitle: decision.ruleID,
          systemImage: "exclamationmark.bubble",
          badge: decision.severityRaw
        )
        .tag(SessionSelection.decision(sessionID: state.sessionID, decisionID: decision.id))
      }
      if decisions.isEmpty {
        Text("No pending decisions")
          .foregroundStyle(.secondary)
      }
    } header: {
      Text("Decisions")
        .badge(Text("\(decisions.count) pending"))
    }
  }
}
