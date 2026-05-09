import HarnessMonitorKit
import SwiftUI

struct SessionSidebar: View {
  let store: HarnessMonitorStore
  let snapshot: HarnessMonitorSessionWindowSnapshot?
  let decisions: [Decision]
  let canPresentSearch: Bool
  @Bindable var state: SessionWindowStateCache
  @Environment(\.undoManager)
  var undoManager
  @State private var currentModifiers: EventModifiers = []
  @State private var agentDropTargetID: String?
  @State private var decisionDropTargetID: String?
  @State private var searchPresentationState = SidebarSearchPresentationState()
  @State private var searchFocusDispatcher = HarnessSidebarSearchFocusDispatcher()

  var targetedDecisionDropID: String? {
    get { decisionDropTargetID }
    nonmutating set { decisionDropTargetID = newValue }
  }

  var body: some View {
    @Bindable var filters = state.decisionFilters
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
    .task(id: (snapshot?.detail?.agents ?? []).map(\.agentId)) {
      state.sidebarOrdering.reconcileAgentOrder(with: snapshot?.detail?.agents ?? [])
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
    .searchable(
      text: $filters.query,
      isPresented: $searchPresentationState.isPresented,
      placement: .sidebar,
      prompt: "Filter decisions"
    )
    .searchScopes($filters.scope) {
      ForEach(DecisionsSidebarSearchScope.allCases) { scope in
        Label(scope.label, systemImage: scope.systemImage)
          .tag(scope)
      }
    }
    .harnessFocusedSceneValue(\.harnessSidebarSearchFocusAction, searchFocusAction)
    .task(id: canPresentSearch) {
      searchFocusDispatcher.handler = { handleSearchFocusRequest() }
    }
    .onChange(of: canPresentSearch, initial: true) { _, canPresent in
      applySearchPresentationAvailability(canPresent)
    }
    .onDisappear {
      searchFocusDispatcher.handler = nil
    }
    .accessibilityValue(decisionSelectionAccessibilityValue)
    .accessibilityIdentifier(HarnessMonitorAccessibility.sessionWindowSidebar)
  }

  private var sessionCodexRuns: [CodexRunSnapshot] {
    store.selectedCodexRuns.filter { $0.sessionId == state.sessionID }
  }

  private func handleSearchFocusRequest() {
    _ = searchPresentationState.requestPresentation(canPresent: canPresentSearch)
  }

  private func applySearchPresentationAvailability(_ canPresent: Bool) {
    guard canPresent else {
      searchPresentationState.isPresented = false
      return
    }
    if searchPresentationState.applyPendingPresentationIfNeeded(canPresent: canPresent) {
      return
    }
    if !state.decisionFilters.query.isEmpty {
      searchPresentationState.isPresented = true
    }
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

  private var searchFocusAction: HarnessSidebarSearchFocus? {
    guard canPresentSearch else {
      return nil
    }
    return HarnessSidebarSearchFocus(
      isAvailable: true,
      menuLabel: .findInDecisions,
      dispatcher: searchFocusDispatcher
    )
  }

  private var routeSection: some View {
    Section {
      ForEach([SessionWindowRoute.overview, .timeline, .terminal]) { route in
        let selection = SessionSelection.route(route)
        SessionSidebarRow(
          title: route.title,
          systemImage: route.systemImage
        )
        .tag(selection)
        .accessibilityIdentifier(HarnessMonitorAccessibility.sessionWindowRoute(route))
      }
    } header: {
      Text("Routes")
        .padding(.top, HarnessMonitorTheme.spacingLG)
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
          isDropTargeted: agentDropTargetID == agent.agentId
        ) { metrics in
          SessionSidebarDragHandle(metrics: metrics)
            .draggable(
              SessionAgentDragPayload(sessionID: state.sessionID, agentID: agent.agentId)
            )
        }
        .tag(selection)
        .dropDestination(for: SessionAgentDragPayload.self) { payloads, _ in
          handleAgentDrop(payloads, before: agent.agentId)
        } isTargeted: { isTargeted in
          agentDropTargetID = isTargeted ? agent.agentId : nil
        }
        .contextMenu {
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
          Button("Copy Agent ID") {
            HarnessMonitorClipboard.copy(agent.agentId)
          }
        }
      }
      ForEach(sessionCodexRuns) { run in
        let selection = SessionSelection.codexRun(sessionID: state.sessionID, runID: run.runId)
        SessionSidebarRow(
          title: SessionCodexRunRowFormatter.title(for: run),
          systemImage: "wand.and.stars",
          severityShape: SessionCodexRunRowFormatter.severityShape(for: run.status),
          severityTint: SessionCodexRunRowFormatter.severityTint(for: run.status)
        ) { _ in EmptyView() }
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

  @ViewBuilder private var tasksSection: some View {
    Section {
      ForEach(snapshot?.detail?.tasks ?? []) { task in
        let selection = SessionSelection.task(sessionID: state.sessionID, taskID: task.taskId)
        SessionSidebarRow(
          title: task.title,
          systemImage: "checklist",
          severityShape: severityShape(for: task.severity),
          severityTint: severityTint(for: task.severity)
        ) { metrics in
          SessionSidebarDragHandle(metrics: metrics)
            .draggable(
              TaskDragPayload(
                sessionID: state.sessionID,
                taskID: task.taskId,
                queuePolicy: task.queuePolicy
              )
            )
        }
        .tag(selection)
        .contextMenu {
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
