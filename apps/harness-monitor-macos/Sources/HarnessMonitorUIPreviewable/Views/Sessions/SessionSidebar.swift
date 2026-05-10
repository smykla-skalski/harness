import HarnessMonitorKit
import SwiftUI

struct SessionSidebar: View {
  let store: HarnessMonitorStore
  let snapshot: HarnessMonitorSessionWindowSnapshot?
  let sessionCodexRuns: [CodexRunSnapshot]
  let decisions: [Decision]
  @Bindable var state: SessionWindowStateCache
  @Environment(\.harnessTextSizeIndex)
  private var textSizeIndex
  @Environment(\.undoManager)
  var undoManager
  @State private var currentModifiers: EventModifiers = []
  @State private var selectionDispatcher = SessionSidebarSelectionDispatcher()
  @State private var listSelection: Set<SessionSelection> = []

  var body: some View {
    List(selection: selectionBinding) {
      routeSection
      agentsSection
      tasksSection
      decisionsSection
    }
    .listStyle(.sidebar)
    .environment(\.sidebarRowSize, sidebarRowSize)
    .onChange(of: decisions.map(\.id)) { _, ids in
      state.sidebarSelection.prune(kind: .decision, visibleIDs: Set(ids))
      pruneListSelection(kind: .decision, visibleIDs: Set(ids))
    }
    .onChange(of: (snapshot?.detail?.agents ?? []).map(\.agentId)) { _, ids in
      state.sidebarSelection.prune(kind: .agent, visibleIDs: Set(ids))
      pruneListSelection(kind: .agent, visibleIDs: Set(ids))
    }
    .onChange(of: (snapshot?.detail?.tasks ?? []).map(\.taskId)) { _, ids in
      state.sidebarSelection.prune(kind: .task, visibleIDs: Set(ids))
      pruneListSelection(kind: .task, visibleIDs: Set(ids))
    }
    .task(id: (snapshot?.detail?.agents ?? []).map(\.agentId)) {
      state.sidebarOrdering.reconcileAgentOrder(with: snapshot?.detail?.agents ?? [])
    }
    .onChange(of: state.decisionBulkActions.reopenRequestedBatch) { _, ids in
      guard let ids else { return }
      Task { await reopenDecisionBatch(ids) }
      state.decisionBulkActions.reopenRequestedBatch = nil
    }
    .onModifierKeysChanged { _, newModifiers in
      if currentModifiers != newModifiers {
        currentModifiers = newModifiers
      }
    }
    .onChange(of: state.lastPlainClick) { _, signal in
      collapseSelectionFromApplicationTap(signal)
    }
    .harnessFocusedSceneValue(\.harnessSessionSidebarSelection, selectionFocus)
    .onChange(of: state.selection) { _, _ in
      setListSelection(renderedSelectionSet())
    }
    .task(id: state.sessionID) {
      setListSelection(renderedSelectionSet())
      bindSelectionDispatcher()
    }
    .onDisappear {
      selectionDispatcher.selectAll = nil
      selectionDispatcher.clearSelection = nil
      selectionDispatcher.deleteSelection = nil
    }
    .accessibilityValue(decisionSelectionAccessibilityValue)
    .accessibilityIdentifier(HarnessMonitorAccessibility.sessionWindowSidebar)
  }

  private var sidebarRowSize: SidebarRowSize {
    switch HarnessMonitorTextSize.normalizedIndex(textSizeIndex) {
    case ..<HarnessMonitorTextSize.defaultIndex:
      .small
    case HarnessMonitorTextSize.defaultIndex..<HarnessMonitorTextSize.scales.count - 1:
      .medium
    default:
      .large
    }
  }

  private var decisionSelectionAccessibilityValue: Text {
    if let anchor = state.sidebarSelection.anchor {
      let count = state.sidebarSelection.count(of: anchor.kind)
      let visible = visibleCount(for: anchor.kind)
      return Text("\(count) of \(visible) \(anchor.kind.pluralNoun) selected")
    }
    if displayedSelectionSet.count > 1 {
      return Text("\(displayedSelectionSet.count) items selected")
    }
    return Text("No multi-selection")
  }

  private func visibleCount(for kind: SessionSidebarSelectionKind) -> Int {
    switch kind {
    case .agent: (snapshot?.detail?.agents ?? []).count
    case .task: (snapshot?.detail?.tasks ?? []).count
    case .decision: decisions.count
    }
  }

  private var selectionBinding: Binding<Set<SessionSelection>> {
    Binding(
      get: { displayedSelectionSet },
      set: { applyListSelection($0) }
    )
  }

  var displayedSelectionSet: Set<SessionSelection> {
    listSelection.isEmpty ? renderedSelectionSet() : listSelection
  }

  private func renderedSelectionSet() -> Set<SessionSelection> {
    var set: Set<SessionSelection> = []
    set.insert(state.selection)
    let sid = state.sessionID
    for id in state.sidebarSelection.selectedAgentIDs {
      set.insert(.agent(sessionID: sid, agentID: id))
    }
    for id in state.sidebarSelection.selectedTaskIDs {
      set.insert(.task(sessionID: sid, taskID: id))
    }
    for id in state.sidebarSelection.selectedDecisionIDs {
      set.insert(.decision(sessionID: sid, decisionID: id))
    }
    return set
  }

  private func applyListSelection(_ new: Set<SessionSelection>) {
    let old = displayedSelectionSet
    guard new != old else { return }
    setListSelection(new)

    if new.isEmpty {
      state.sidebarSelection.clear()
      return
    }

    let added = new.subtracting(old)
    let pivot = added.first ?? new.first
    guard let pivotItem = pivot else { return }

    if new.count == 1 {
      state.sidebarSelection.clear()
      state.selectFromSidebar(pivotItem)
      return
    }

    guard let actionableSelection = actionableMultiSelection(from: new) else {
      state.sidebarSelection.clear()
      return
    }

    let anchorID = multiSelectID(of: pivotItem) ?? state.sidebarSelection.anchor?.id
    state.sidebarSelection.applyChange(
      kind: actionableSelection.kind,
      selectedIDs: actionableSelection.ids,
      anchorID: anchorID
    )
    state.sidebarAnnouncer.announce(
      kind: actionableSelection.kind,
      count: actionableSelection.ids.count,
      visibleCount: visibleCount(for: actionableSelection.kind)
    )
  }

  /// Native `List(selection: Set<>)` does not collapse a multi-selection when the
  /// user plain-clicks a row that is already in the set — the selection is left
  /// alone. Mirror the legacy app's collapse-on-tap so plain clicks act like a
  /// "back to single-select on this row" intent.
  func collapseToRowFromPlainTap(_ selection: SessionSelection) {
    let blocking = currentModifiers.intersection([.command, .shift, .control, .option])
    guard blocking.isEmpty else { return }
    guard hasActiveMultiSelection else { return }
    state.sidebarSelection.clear()
    state.selectFromSidebar(selection)
    setListSelection([selection])
  }

  /// Plain tap anywhere in the SessionWindow (outside the sidebar list).
  /// Mirrors legacy `collapseSelectionFromApplicationTap`: bail on modifiers,
  /// otherwise clear the multi-extension and leave primary intact.
  private func collapseSelectionFromApplicationTap(_ signal: SessionPlainClickSignal) {
    let blocking = signal.modifiers.intersection([.command, .shift, .control, .option])
    guard blocking.isEmpty else { return }
    guard hasActiveMultiSelection else { return }
    state.sidebarSelection.clear()
    setListSelection([state.selection])
  }

  var hasActiveMultiSelection: Bool {
    state.sidebarSelection.hasActiveMultiSelection
  }

  private func setListSelection(_ selection: Set<SessionSelection>) {
    listSelection = selection
    state.sidebarSelection.syncRenderedSelectionCount(selection.count)
  }

  private func actionableMultiSelection(
    from selection: Set<SessionSelection>
  ) -> (kind: SessionSidebarSelectionKind, ids: Set<String>)? {
    let kinds = Set(selection.compactMap { multiSelectKind(of: $0) })
    guard kinds.count == 1, let kind = kinds.first else { return nil }
    let ids = Set(selection.compactMap { multiSelectID(of: $0) })
    guard ids.count == selection.count else { return nil }
    return (kind, ids)
  }

  private func pruneListSelection(
    kind: SessionSidebarSelectionKind,
    visibleIDs: Set<String>
  ) {
    let current = displayedSelectionSet
    let pruned = current.filter { selection in
      guard multiSelectKind(of: selection) == kind else { return true }
      guard let selectionID = multiSelectID(of: selection) else { return true }
      return visibleIDs.contains(selectionID)
    }
    if pruned != current {
      setListSelection(pruned)
    }
  }

  private func multiSelectKind(of selection: SessionSelection) -> SessionSidebarSelectionKind? {
    switch selection {
    case .agent: .agent
    case .task: .task
    case .decision: .decision
    case .route, .codexRun, .create: nil
    }
  }

  private func multiSelectID(of selection: SessionSelection) -> String? {
    switch selection {
    case .agent(_, let id): id
    case .task(_, let id): id
    case .decision(_, let id): id
    case .route, .codexRun, .create: nil
    }
  }

  private var routeSection: some View {
    Section {
      ForEach([SessionWindowRoute.overview, .decisions, .timeline, .terminal]) { route in
        let selection = SessionSelection.route(route)
        SessionSidebarRow(
          title: route.title,
          systemImage: route.systemImage
        )
        .tag(selection)
        .accessibilityIdentifier(HarnessMonitorAccessibility.sessionWindowRoute(route))
        .contextMenu {
          Button(SessionSidebarContextMenuScope.unavailableLabel) {}
            .disabled(true)
        }
      }
    } header: {
      Text("Routes")
        .padding(.top, HarnessMonitorTheme.spacingLG)
    }
  }

  private var selectionFocus: SessionSidebarSelectionFocus {
    let hasMulti = displayedSelectionSet.count > 1
    let canDelete: Bool = {
      guard let anchor = state.sidebarSelection.anchor else { return false }
      return state.sidebarSelection.count(of: anchor.kind) > 0
    }()
    return SessionSidebarSelectionFocus(
      hasMultiSelection: hasMulti,
      canDelete: canDelete,
      dispatcher: selectionDispatcher
    )
  }

  /// Closures live-read the prop closures captured here. The captures are
  /// `[state, agentIDsClosure, taskIDsClosure, decisionIDsClosure]` so the
  /// dispatcher reads the *current* visible IDs at fire time, not whatever
  /// snapshot was current when this method was last called.
  private func bindSelectionDispatcher() {
    let agentIDsProvider: () -> [String] = { [self] in
      (self.snapshot?.detail?.agents ?? []).map(\.agentId)
    }
    let taskIDsProvider: () -> [String] = { [self] in
      (self.snapshot?.detail?.tasks ?? []).map(\.taskId)
    }
    let decisionIDsProvider: () -> [String] = { [self] in
      self.decisions.map(\.id)
    }
    selectionDispatcher.selectAll =
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
    selectionDispatcher.clearSelection = { [state] in
      let priorKind = state.sidebarSelection.anchor?.kind
      state.sidebarSelection.clear()
      setListSelection([state.selection])
      if let priorKind {
        state.sidebarAnnouncer.announce(kind: priorKind, count: 0, visibleCount: 0)
      }
    }
    selectionDispatcher.deleteSelection =
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
        case .decision: dismissDecisions(ids)
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
