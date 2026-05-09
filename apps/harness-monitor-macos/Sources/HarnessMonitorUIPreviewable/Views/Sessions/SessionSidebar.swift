import HarnessMonitorKit
import SwiftUI

struct SessionSidebar: View {
  let store: HarnessMonitorStore
  let snapshot: HarnessMonitorSessionWindowSnapshot?
  let sessionCodexRuns: [CodexRunSnapshot]
  let decisions: [Decision]
  let canPresentSearch: Bool
  @Bindable var state: SessionWindowStateCache
  @Environment(\.harnessTextSizeIndex) private var textSizeIndex
  @Environment(\.undoManager)
  var undoManager
  @State var currentModifiers: EventModifiers = []
  @State private var searchPresentationState = SidebarSearchPresentationState()
  @State private var searchFocusDispatcher = HarnessSidebarSearchFocusDispatcher()
  @State private var selectionDispatcher = SessionSidebarSelectionDispatcher()

  var body: some View {
    @Bindable var filters = state.decisionFilters
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
    }
    .onChange(of: (snapshot?.detail?.agents ?? []).map(\.agentId)) { _, ids in
      state.sidebarSelection.prune(kind: .agent, visibleIDs: Set(ids))
    }
    .onChange(of: (snapshot?.detail?.tasks ?? []).map(\.taskId)) { _, ids in
      state.sidebarSelection.prune(kind: .task, visibleIDs: Set(ids))
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
    .harnessFocusedSceneValue(\.harnessSessionSidebarSelection, selectionFocus)
    .task(id: canPresentSearch) {
      searchFocusDispatcher.handler = { handleSearchFocusRequest() }
    }
    .onChange(of: canPresentSearch, initial: true) { _, canPresent in
      applySearchPresentationAvailability(canPresent)
    }
    .task(id: state.sessionID) {
      bindSelectionDispatcher()
    }
    .onDisappear {
      searchFocusDispatcher.handler = nil
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
    if let anchor = state.sidebarSelection.anchor {
      let count = state.sidebarSelection.count(of: anchor.kind)
      let visible = visibleCount(for: anchor.kind)
      return Text("\(count) of \(visible) \(anchor.kind.pluralNoun) selected")
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
      get: { renderedSelectionSet() },
      set: { applyListSelection($0) }
    )
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
    let old = renderedSelectionSet()
    guard new != old else { return }

    if new.isEmpty {
      state.sidebarSelection.clear()
      state.selectFromSidebar(nil)
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

    guard let kind = multiSelectKind(of: pivotItem) else {
      state.sidebarSelection.clear()
      state.selectFromSidebar(pivotItem)
      return
    }

    let oldHasSameKind = old.contains { multiSelectKind(of: $0) == kind }
    guard oldHasSameKind else {
      state.sidebarSelection.clear()
      state.selectFromSidebar(pivotItem)
      return
    }

    let filtered = new.filter { multiSelectKind(of: $0) == kind }
    let ids = Set(filtered.compactMap { multiSelectID(of: $0) })
    let anchorID = multiSelectID(of: pivotItem) ?? state.sidebarSelection.anchor?.id
    state.sidebarSelection.applyChange(
      kind: kind,
      selectedIDs: ids,
      anchorID: anchorID
    )
    state.sidebarAnnouncer.announce(
      kind: kind,
      count: ids.count,
      visibleCount: visibleCount(for: kind)
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
  }

  /// Plain tap anywhere in the SessionWindow (outside the sidebar list).
  /// Mirrors legacy `collapseSelectionFromApplicationTap`: bail on modifiers,
  /// otherwise clear the multi-extension and leave primary intact.
  private func collapseSelectionFromApplicationTap(_ signal: SessionPlainClickSignal) {
    let blocking = signal.modifiers.intersection([.command, .shift, .control, .option])
    guard blocking.isEmpty else { return }
    guard hasActiveMultiSelection else { return }
    state.sidebarSelection.clear()
  }

  var hasActiveMultiSelection: Bool {
    state.sidebarSelection.selectedAgentIDs.count > 1
      || state.sidebarSelection.selectedTaskIDs.count > 1
      || state.sidebarSelection.selectedDecisionIDs.count > 1
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

  private var selectionFocus: SessionSidebarSelectionFocus {
    let hasMulti = state.sidebarSelection.anchor != nil
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
    selectionDispatcher.selectAll = {
      [state, agentIDsProvider, taskIDsProvider, decisionIDsProvider] in
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
      if let priorKind {
        state.sidebarAnnouncer.announce(kind: priorKind, count: 0, visibleCount: 0)
      }
    }
    selectionDispatcher.deleteSelection = {
      [agentIDsProvider, taskIDsProvider, decisionIDsProvider] in
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
