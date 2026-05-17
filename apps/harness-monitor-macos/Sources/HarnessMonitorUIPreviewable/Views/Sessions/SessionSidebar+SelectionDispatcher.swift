import HarnessMonitorKit

extension SessionSidebar {
  var selectionFocus: SessionSidebarSelectionFocus {
    let hasMulti = displayedSelectionSet.count > 1
    let canDelete: Bool = {
      guard let anchor = state.sidebarSelection.anchor else { return false }
      guard state.sidebarSelection.count(of: anchor.kind) > 0 else { return false }
      switch anchor.kind {
      case .agent, .task:
        return true
      case .decision:
        return false
      }
    }()
    return SessionSidebarSelectionFocus(
      hasMultiSelection: hasMulti,
      canDelete: canDelete,
      dispatcher: sidebarSelectionDispatcher
    )
  }

  /// Closures live-read the prop closures captured here. The captures are
  /// `[state, agentIDsClosure, taskIDsClosure, decisionIDsClosure]` so the
  /// dispatcher reads the current visible IDs at fire time, not whatever
  /// snapshot was current when this method was last called.
  func bindSelectionDispatcher() {
    let agentIDsProvider: () -> [String] = { [self] in
      self.visibleAgentIDs
    }
    let taskIDsProvider: () -> [String] = { [self] in
      self.visibleTaskIDs
    }
    let decisionIDsProvider: () -> [String] = { [self] in
      self.decisionIDs
    }
    sidebarSelectionDispatcher.selectAll =
      { [self, state, agentIDsProvider, taskIDsProvider, decisionIDsProvider] in
        let agents = agentIDsProvider()
        let tasks = taskIDsProvider()
        let decisions = decisionIDsProvider()
        let inferred = SessionSidebarSelectionKind.inferredAnchorKind(
          agentCount: agents.count,
          taskCount: tasks.count,
          decisionCount: decisions.count
        )
        let kind = state.sidebarSelection.anchor?.kind ?? inferred
        guard let kind else { return }
        let visible = SessionSidebarSelectionKind.visibleIDs(
          for: kind,
          agents: agents,
          tasks: tasks,
          decisions: decisions
        )
        setListSelection(Set(visible.map { sidebarSelection(for: kind, id: $0) }))
        state.sidebarSelection.applyChange(
          kind: kind,
          selectedIDs: Set(visible),
          anchorID: visible.first
        )
        state.sidebarAnnouncer.announce(
          kind: kind,
          count: visible.count,
          visibleCount: visible.count
        )
      }
    sidebarSelectionDispatcher.clearSelection = { [state] in
      let priorKind = state.sidebarSelection.anchor?.kind
      state.sidebarSelection.clear()
      setListSelection([state.selection])
      if let priorKind {
        state.sidebarAnnouncer.announce(kind: priorKind, count: 0, visibleCount: 0)
      }
    }
    sidebarSelectionDispatcher.deleteSelection =
      { [agentIDsProvider, taskIDsProvider, decisionIDsProvider] in
        guard let anchor = state.sidebarSelection.anchor else { return }
        let ordered = SessionSidebarSelectionKind.visibleIDs(
          for: anchor.kind,
          agents: agentIDsProvider(),
          tasks: taskIDsProvider(),
          decisions: decisionIDsProvider()
        )
        let set = state.sidebarSelection.selectedIDs(of: anchor.kind)
        let ids = ordered.filter { set.contains($0) }
        guard !ids.isEmpty else { return }
        switch anchor.kind {
        case .agent: requestRemoveAgents(ids)
        case .task: requestDeleteTasks(ids)
        case .decision: return
        }
      }
  }
}

extension SessionSidebarSelectionKind {
  fileprivate static func visibleIDs(
    for kind: SessionSidebarSelectionKind,
    agents: [String],
    tasks: [String],
    decisions: [String]
  ) -> [String] {
    switch kind {
    case .agent: agents
    case .task: tasks
    case .decision: decisions
    }
  }
}
