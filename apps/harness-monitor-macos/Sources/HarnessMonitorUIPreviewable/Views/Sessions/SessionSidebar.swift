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
    .onChange(of: state.sidebarSelection.isDecisionMultiSelectEnabled) { _, enabled in
      guard enabled else { return }
      state.sidebarAnnouncer.announce(
        kind: .decision,
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

  func handleDecisionRowTap(_ decisionID: String) {
    handleSidebarRowTap(
      kind: .decision,
      rowID: decisionID,
      orderedVisibleIDs: decisions.map(\.id)
    )
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
