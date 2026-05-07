import HarnessMonitorKit
import SwiftUI

struct SessionSidebar: View {
  let snapshot: HarnessMonitorSessionWindowSnapshot?
  let decisions: [Decision]
  @Bindable var state: SessionWindowStateCache
  @Environment(\.undoManager) private var undoManager
  @State private var agentDropTargetID: String?
  @State private var decisionDropTargetID: String?

  var body: some View {
    List(selection: selectionBinding) {
      routeSection
      agentsSection
      tasksSection
      decisionsSection
    }
    .listStyle(.sidebar)
    .onChange(of: decisions.map(\.id)) { _, ids in
      state.sidebarSelection.pruneDecisionSelection(to: Set(ids))
    }
    .accessibilityIdentifier(HarnessMonitorAccessibility.sessionWindowSidebar)
  }

  private var selectionBinding: Binding<SessionSelection?> {
    Binding(
      get: { state.selection },
      set: { state.select($0 ?? .route(.overview)) }
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
    Section {
      ForEach(state.sidebarOrdering.orderedAgents(snapshot?.detail?.agents ?? [])) { agent in
        SessionSidebarRow(
          title: agent.name,
          systemImage: "person.crop.circle",
          severityShape: severityShape(for: agent.status),
          severityTint: severityTint(for: agent.status),
          showsDragHandle: true,
          isDropTargeted: agentDropTargetID == agent.agentId
        )
        .tag(SessionSelection.agent(sessionID: state.sessionID, agentID: agent.agentId))
        .draggable(SessionAgentDragPayload(sessionID: state.sessionID, agentID: agent.agentId))
        .dropDestination(for: SessionAgentDragPayload.self) { payloads, _ in
          handleAgentDrop(payloads, before: agent.agentId)
        } isTargeted: { isTargeted in
          agentDropTargetID = isTargeted ? agent.agentId : nil
        }
        .contextMenu {
          Button("Move to Top") {
            state.sidebarOrdering.moveAgent(
              agent.agentId,
              before: state.sidebarOrdering.agentIDs.first,
              undoManager: undoManager
            )
          }
          Button("Move to Bottom") {
            state.sidebarOrdering.moveAgent(
              agent.agentId,
              before: nil,
              undoManager: undoManager
            )
          }
          Divider()
          Button("Copy Agent ID") {
            HarnessMonitorClipboard.copy(agent.agentId)
          }
        }
      }
      if (snapshot?.detail?.agents ?? []).isEmpty {
        Text("No agents")
          .foregroundStyle(.secondary)
      }
    } header: {
      HStack {
        Text("Agents")
        Spacer()
        Button {
          state.selectCreate(.agent)
        } label: {
          Image(systemName: "plus")
        }
        .buttonStyle(.borderless)
        .help("New Agent")
        .accessibilityLabel("New Agent")
      }
    }
  }

  @ViewBuilder private var tasksSection: some View {
    Section {
      ForEach(snapshot?.detail?.tasks ?? []) { task in
        SessionSidebarRow(
          title: task.title,
          systemImage: "checklist",
          severityShape: severityShape(for: task.severity),
          severityTint: severityTint(for: task.severity),
          showsDragHandle: true
        )
        .tag(SessionSelection.task(sessionID: state.sessionID, taskID: task.taskId))
        .draggable(
          TaskDragPayload(
            sessionID: state.sessionID,
            taskID: task.taskId,
            queuePolicy: task.queuePolicy
          )
        )
        .contextMenu {
          Button("Copy Task ID") {
            HarnessMonitorClipboard.copy(task.taskId)
          }
        }
      }
      if (snapshot?.detail?.tasks ?? []).isEmpty {
        Text("No tasks")
          .foregroundStyle(.secondary)
      }
    }
    header: {
      taskSectionHeader
    }
  }

  @ViewBuilder private var decisionsSection: some View {
    Section {
      ForEach(decisions) { decision in
        let severity = DecisionSeverity(rawValue: decision.severityRaw)
        SessionSidebarRow(
          title: decision.summary,
          systemImage: "exclamationmark.bubble",
          severityShape: severityShape(for: severity),
          severityTint: severityTint(for: severity),
          isDropTargeted: decisionDropTargetID == decision.id,
          isMultiSelect: state.sidebarSelection.isDecisionMultiSelectEnabled,
          isSelected: state.sidebarSelection.selectedDecisionIDs.contains(decision.id),
          toggleSelection: {
            state.sidebarSelection.toggleDecision(decision.id)
          }
        )
        .tag(SessionSelection.decision(sessionID: state.sessionID, decisionID: decision.id))
        .dropDestination(for: TaskDragPayload.self) { payloads, _ in
          handleTaskDecisionDrop(payloads, decisionID: decision.id)
        } isTargeted: { isTargeted in
          decisionDropTargetID = isTargeted ? decision.id : nil
        }
        .contextMenu {
          Button("Copy Decision ID") {
            HarnessMonitorClipboard.copy(decision.id)
          }
        }
      }
      if decisions.isEmpty {
        Text("No pending decisions")
          .foregroundStyle(.secondary)
      }
    } header: {
      decisionsHeader
    }
  }

  private var taskSectionHeader: some View {
    HStack {
      Text("Tasks")
      Spacer()
      Button {
        state.selectCreate(.task)
      } label: {
        Image(systemName: "plus")
      }
      .buttonStyle(.borderless)
      .help("New Task")
      .accessibilityLabel("New Task")
    }
  }

  private var decisionsHeader: some View {
    HStack {
      Text("Decisions")
        .badge(Text("\(decisions.count) pending"))
      Spacer()
      Button {
        state.sidebarSelection.toggleDecisionMultiSelect()
      } label: {
        Image(
          systemName: state.sidebarSelection.isDecisionMultiSelectEnabled
            ? "checkmark.circle.fill"
            : "checkmark.circle"
        )
      }
      .buttonStyle(.borderless)
      .help("Select Decisions")
      .accessibilityLabel("Select Decisions")
      Button {
        state.selectCreate(.decision)
      } label: {
        Image(systemName: "plus")
      }
      .buttonStyle(.borderless)
      .help("New Decision")
      .accessibilityLabel("New Decision")
    }
  }

  private func handleAgentDrop(
    _ payloads: [SessionAgentDragPayload],
    before agentID: String
  ) -> Bool {
    guard let payload = payloads.first, payload.sessionID == state.sessionID else {
      return false
    }
    state.sidebarOrdering.moveAgent(
      payload.agentID,
      before: agentID,
      undoManager: undoManager
    )
    return true
  }

  private func handleTaskDecisionDrop(
    _ payloads: [TaskDragPayload],
    decisionID: String
  ) -> Bool {
    guard let payload = payloads.first, payload.sessionID == state.sessionID else {
      return false
    }
    state.lastTaskDecisionLink = SessionTaskDecisionLink(
      sessionID: state.sessionID,
      taskID: payload.taskID,
      decisionID: decisionID
    )
    return true
  }

  private func severityShape(for status: AgentStatus) -> SessionSidebarSeverityShape {
    switch status {
    case .active: .dot
    case .awaitingReview: .alert
    case .idle: .none
    case .disconnected, .removed: .ring
    }
  }

  private func severityTint(for status: AgentStatus) -> Color {
    switch status {
    case .active, .awaitingReview: .accentColor
    case .idle, .disconnected, .removed: .gray
    }
  }

  private func severityShape(for severity: TaskSeverity) -> SessionSidebarSeverityShape {
    switch severity {
    case .low: .none
    case .medium: .dot
    case .high: .ring
    case .critical: .alert
    }
  }

  private func severityTint(for severity: TaskSeverity) -> Color {
    switch severity {
    case .low: .gray
    case .medium, .high, .critical: .accentColor
    }
  }

  private func severityShape(for severity: DecisionSeverity?) -> SessionSidebarSeverityShape {
    switch severity {
    case .info: .dot
    case .warn: .ring
    case .needsUser, .critical: .alert
    case .none: .none
    }
  }

  private func severityTint(for severity: DecisionSeverity?) -> Color {
    switch severity {
    case .info, .none: .gray
    case .warn, .needsUser, .critical: .accentColor
    }
  }
}
