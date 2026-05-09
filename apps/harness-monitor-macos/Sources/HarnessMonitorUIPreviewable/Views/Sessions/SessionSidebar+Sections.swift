import HarnessMonitorKit
import SwiftUI

extension SessionSidebar {
  @ViewBuilder var agentsSection: some View {
    Section {
      let orderedAgents = state.sidebarOrdering.orderedAgents(snapshot?.detail?.agents ?? [])
      let orderedAgentIDs = orderedAgents.map(\.agentId)
      ForEach(orderedAgents) { agent in
        agentRow(agent, orderedAgentIDs: orderedAgentIDs)
      }
      ForEach(sessionCodexRuns) { run in
        let selection = SessionSelection.codexRun(sessionID: state.sessionID, runID: run.runId)
        SessionSidebarRow(
          title: SessionCodexRunRowFormatter.title(for: run),
          systemImage: "wand.and.stars",
          severityShape: SessionCodexRunRowFormatter.severityShape(for: run.status),
          severityTint: SessionCodexRunRowFormatter.severityTint(for: run.status)
        )
        .tag(selection)
        .contextMenu {
          Button("Copy Run ID") {
            HarnessMonitorClipboard.copy(run.runId)
          }
        }
      }
      if (snapshot?.detail?.agents ?? []).isEmpty && sessionCodexRuns.isEmpty {
        Text("No agents")
          .foregroundStyle(.secondary)
      }
    } header: {
      agentsSectionHeader
    }
  }

  @ViewBuilder var tasksSection: some View {
    Section {
      let tasks = snapshot?.detail?.tasks ?? []
      let orderedTaskIDs = tasks.map(\.taskId)
      ForEach(tasks) { task in
        taskRow(task, orderedTaskIDs: orderedTaskIDs)
      }
      if (snapshot?.detail?.tasks ?? []).isEmpty {
        Text("No tasks")
          .foregroundStyle(.secondary)
      }
    } header: {
      taskSectionHeader
    }
  }

  @ViewBuilder
  private func agentRow(
    _ agent: AgentRegistration,
    orderedAgentIDs: [String]
  ) -> some View {
    let selection = SessionSelection.agent(sessionID: state.sessionID, agentID: agent.agentId)
    SessionSidebarRow(
      title: agent.name,
      systemImage: "person.crop.circle",
      severityShape: severityShape(for: agent.status),
      severityTint: severityTint(for: agent.status)
    )
    .tag(selection)
    .accessibilityIdentifier(HarnessMonitorAccessibility.sidebarAgentRow(agent.agentId))
    .simultaneousGesture(
      SpatialTapGesture().onEnded { _ in
        collapseToRowFromPlainTap(selection)
      },
      including: hasActiveMultiSelection ? .gesture : []
    )
    .contextMenu {
      agentRowContextMenu(agent, orderedAgentIDs: orderedAgentIDs)
    }
  }

  @ViewBuilder
  private func agentRowContextMenu(
    _ agent: AgentRegistration,
    orderedAgentIDs: [String]
  ) -> some View {
    let scope = SessionSidebarContextMenuScope.resolve(
      kind: .agent,
      rowID: agent.agentId,
      selectedIDs: state.sidebarSelection.selectedAgentIDs,
      orderedVisibleIDs: orderedAgentIDs
    )
    if !scope.isMulti {
      Menu("Move to...") {
        Button("Top") {
          state.sidebarOrdering.moveAgent(
            agent.agentId,
            before: state.sidebarOrdering.agentIDs.first,
            undoManager: undoManager
          )
        }
        Button("Bottom") {
          state.sidebarOrdering.moveAgent(
            agent.agentId,
            before: nil,
            undoManager: undoManager
          )
        }
      }
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
    }
    Button(scope.copyIDsLabel) {
      HarnessMonitorClipboard.copy(scope.clipboardText)
    }
    Divider()
    Button(scope.destructiveLabel, role: .destructive) {
      requestRemoveAgents(scope.ids)
    }
  }

  @ViewBuilder
  private func taskRow(
    _ task: WorkItem,
    orderedTaskIDs: [String]
  ) -> some View {
    let selection = SessionSelection.task(sessionID: state.sessionID, taskID: task.taskId)
    SessionSidebarRow(
      title: task.title,
      systemImage: "checklist",
      severityShape: severityShape(for: task.severity),
      severityTint: severityTint(for: task.severity)
    )
    .tag(selection)
    .accessibilityIdentifier(HarnessMonitorAccessibility.sidebarTaskRow(task.taskId))
    .simultaneousGesture(
      SpatialTapGesture().onEnded { _ in
        collapseToRowFromPlainTap(selection)
      },
      including: hasActiveMultiSelection ? .gesture : []
    )
    .contextMenu {
      taskRowContextMenu(task, orderedTaskIDs: orderedTaskIDs)
    }
  }

  @ViewBuilder
  private func taskRowContextMenu(
    _ task: WorkItem,
    orderedTaskIDs: [String]
  ) -> some View {
    let scope = SessionSidebarContextMenuScope.resolve(
      kind: .task,
      rowID: task.taskId,
      selectedIDs: state.sidebarSelection.selectedTaskIDs,
      orderedVisibleIDs: orderedTaskIDs
    )
    if !scope.isMulti {
      Menu("Move to...") {
        ForEach(decisions.prefix(10)) { decision in
          Button(decision.summary) {
            linkTask(task.taskId, to: decision.id)
          }
        }
        if decisions.isEmpty {
          Text("No visible decisions")
        }
        if decisions.count > 10 {
          Text("Filter decisions to show more")
        }
      }
    }
    Button(scope.copyIDsLabel) {
      HarnessMonitorClipboard.copy(scope.clipboardText)
    }
    Divider()
    Button(scope.destructiveLabel, role: .destructive) {
      requestDeleteTasks(scope.ids)
    }
  }

  private var agentsSectionHeader: some View {
    HStack(spacing: 6) {
      Text("Agents")
      if state.sectionState.hasDraft(.agent) {
        Image(systemName: "circle.fill")
          .font(.caption2)
          .foregroundStyle(.tint)
          .accessibilityLabel("Unsaved draft")
      }
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

  private var taskSectionHeader: some View {
    HStack(spacing: 6) {
      Text("Tasks")
      if state.sectionState.hasDraft(.task) {
        Image(systemName: "circle.fill")
          .font(.caption2)
          .foregroundStyle(.tint)
          .accessibilityLabel("Unsaved draft")
      }
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
}
