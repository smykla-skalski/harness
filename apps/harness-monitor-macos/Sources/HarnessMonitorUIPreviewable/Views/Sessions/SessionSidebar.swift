import HarnessMonitorKit
import SwiftUI

struct SessionSidebar: View {
  let store: HarnessMonitorStore
  let snapshot: HarnessMonitorSessionWindowSnapshot?
  let decisions: [Decision]
  @Bindable var state: SessionWindowStateCache
  @Environment(\.undoManager)
  var undoManager
  @State private var currentModifiers: EventModifiers = []
  @State private var agentDropTargetID: String?
  @State private var decisionDropTargetID: String?

  var targetedDecisionDropID: String? {
    get { decisionDropTargetID }
    nonmutating set { decisionDropTargetID = newValue }
  }

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
    .onChange(of: state.decisionBulkActions.reopenRequestedBatch) { _, ids in
      guard let ids else { return }
      Task { await reopenDecisionBatch(ids) }
      state.decisionBulkActions.reopenRequestedBatch = nil
    }
    .onChange(of: state.sidebarSelection.selectedDecisionIDs.count) { previous, count in
      guard previous != count else { return }
      guard state.sidebarSelection.isDecisionMultiSelectEnabled else { return }
      SessionSidebarMultiSelectAnnouncer.announce(
        count: count,
        visibleCount: decisions.count
      )
    }
    .onChange(of: state.sidebarSelection.isDecisionMultiSelectEnabled) { _, enabled in
      guard enabled else { return }
      SessionSidebarMultiSelectAnnouncer.announce(
        count: state.sidebarSelection.selectedDecisionIDs.count,
        visibleCount: decisions.count
      )
    }
    .onModifierKeysChanged { _, modifiers in
      currentModifiers = modifiers
    }
    .searchable(text: decisionQueryBinding, placement: .sidebar, prompt: "Filter decisions")
    .searchScopes(decisionScopeBinding) {
      ForEach(DecisionsSidebarSearchScope.allCases) { scope in
        Label(scope.label, systemImage: scope.systemImage)
          .tag(scope)
      }
    }
    .accessibilityValue(decisionSelectionAccessibilityValue)
    .accessibilityIdentifier(HarnessMonitorAccessibility.sessionWindowSidebar)
  }

  private var decisionSelectionAccessibilityValue: Text {
    guard state.sidebarSelection.isDecisionMultiSelectEnabled else {
      return Text("Decision multi-select off")
    }
    let count = state.sidebarSelection.selectedDecisionIDs.count
    return Text("\(count) of \(decisions.count) decisions selected")
  }

  private var selectionBinding: Binding<SessionSelection?> {
    Binding(
      get: { state.selection },
      set: { state.selectFromSidebar($0) }
    )
  }

  private var decisionQueryBinding: Binding<String> {
    Binding(
      get: { state.decisionFilters.query },
      set: { state.decisionFilters.query = $0 }
    )
  }

  private var decisionScopeBinding: Binding<DecisionsSidebarSearchScope> {
    Binding(
      get: { state.decisionFilters.scope },
      set: { state.decisionFilters.scope = $0 }
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
        let selection = SessionSelection.agent(sessionID: state.sessionID, agentID: agent.agentId)
        SessionSidebarRow(
          title: agent.name,
          systemImage: "person.crop.circle",
          severityShape: severityShape(for: agent.status),
          severityTint: severityTint(for: agent.status),
          showsDragHandle: true,
          isDropTargeted: agentDropTargetID == agent.agentId
        )
        .tag(selection)
        .simultaneousGesture(pointerSelectionGesture(for: selection))
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
  }

  private func pointerSelectionGesture(for selection: SessionSelection) -> some Gesture {
    DragGesture(minimumDistance: 0)
      .onChanged { _ in
        state.markPointerSelectionIntent(for: selection)
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
    } header: {
      taskSectionHeader
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

  func handleDecisionRowTap(_ decisionID: String) {
    let change = SessionSidebarMultiSelect.resolve(
      rowID: decisionID,
      orderedVisibleIDs: decisions.map(\.id),
      selectedIDs: state.sidebarSelection.selectedDecisionIDs,
      anchorID: state.sidebarSelection.decisionSelectionAnchorID,
      modifiers: currentModifiers
    )
    state.sidebarSelection.selectedDecisionIDs = change.selectedIDs
    state.sidebarSelection.decisionSelectionAnchorID = change.anchorID
    if change.activatesRow {
      state.select(.decision(sessionID: state.sessionID, decisionID: decisionID))
    }
  }
}
