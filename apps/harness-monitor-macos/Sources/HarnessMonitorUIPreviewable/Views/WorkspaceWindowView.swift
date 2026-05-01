import HarnessMonitorKit
import SwiftUI

struct ClickableSwitchStyle: ToggleStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack {
      configuration.label
        .contentShape(Rectangle())
        .onTapGesture {
          configuration.isOn.toggle()
        }
      Toggle("", isOn: configuration.$isOn)
        .toggleStyle(.switch)
        .labelsHidden()
    }
  }
}

private enum WorkspaceChromeMetrics {
  static let sidebarMinWidth: CGFloat = 240
  static let sidebarIdealWidth: CGFloat = 280
  static let sidebarMaxWidth: CGFloat = 400
}

public struct WorkspaceWindowView: View {
  private static let initialDecisionFilters = DecisionsSidebarViewModel.FilterState(
    query: "",
    severities: [],
    scope: .summary
  )

  struct DismissBatchSnapshot: Equatable {
    let ids: [String]
    let count: Int
    let filterSignature: String
    let scopeDescription: String
    let capturedAt: Date
  }

  struct ReopenBatchState: Equatable {
    let ids: [String]
    let expiresAt: Date
  }

  let store: HarnessMonitorStore
  let navigationBridge: WorkspaceWindowNavigationBridge
  @Environment(\.openWindow)
  var openWindow
  @State private var stateViewModel: ViewModel
  @State private var decisionsRuntime = WorkspaceDecisionRuntime()
  @State private var decisionFilters = Self.initialDecisionFilters
  // Cache the expensive visible decision snapshot by decisions + filters only.
  // Selection stays live in `decisionWorkspaceScope` so selection hops never
  // rebuild the filtered/grouped sidebar data.
  @State private var decisionWorkspaceSnapshotState = DecisionWorkspaceScope(
    decisions: [],
    filters: Self.initialDecisionFilters
  )
  @State private var decisionDetailTab: DecisionDetailTab = .context
  @State private var dismissAllVisibleDraft = ""
  @State private var pendingDismissBatch: DismissBatchSnapshot?
  @State private var showDismissAllVisibleConfirmation = false
  @State private var reopenBatch: ReopenBatchState?
  @State private var decisionInspectorVisible = false
  @AppStorage(HarnessMonitorAgentTuiDefaults.submitSendsEnterKey)
  var submitSendsEnter = HarnessMonitorAgentTuiDefaults.submitSendsEnterDefault
  @Environment(\.fontScale)
  private var stateFontScale
  @FocusState private var stateFocusedField: Field?

  @MainActor
  public init(
    store: HarnessMonitorStore,
    navigationBridge: WorkspaceWindowNavigationBridge = WorkspaceWindowNavigationBridge()
  ) {
    self.store = store
    self.navigationBridge = navigationBridge
    let initialDisplayState = AgentTuiDisplayState(initialWindowStore: store)
    let initialSelection = Self.initialSelection(
      displayState: initialDisplayState,
      selectedTerminalID: store.selectedAgentTui?.tuiId,
      selectedCodexRunID: store.selectedCodexRun?.runId
    )
    _stateViewModel = State(
      wrappedValue: ViewModel(
        selection: initialSelection,
        displayState: initialDisplayState,
        createSessionID: store.selectedSessionID
      )
    )
    _decisionWorkspaceSnapshotState = State(
      initialValue: DecisionWorkspaceScope(
        decisions: [],
        filters: Self.initialDecisionFilters
      )
    )
  }

  var cachedDecisionWorkspaceSnapshot: DecisionWorkspaceScope {
    decisionWorkspaceSnapshotState
  }

  func replaceDecisionWorkspaceSnapshot(_ nextSnapshot: DecisionWorkspaceScope) {
    guard decisionWorkspaceSnapshotState != nextSnapshot else {
      return
    }
    decisionWorkspaceSnapshotState = nextSnapshot
  }

  let commonKeys: [AgentTuiKey] = [
    .enter, .tab, .escape, .backspace, .arrowUp, .arrowDown, .arrowLeft, .arrowRight,
  ]

  var viewModel: ViewModel { stateViewModel }

  @MainActor var displayState: AgentTuiDisplayState {
    viewModel.displayState
  }

  var fontScale: CGFloat { stateFontScale }

  var focusedField: Field? {
    get { stateFocusedField }
    nonmutating set { stateFocusedField = newValue }
  }

  var focusedFieldBinding: FocusState<Field?>.Binding { $stateFocusedField }

  var decisionInspectorBinding: Binding<Bool> {
    Binding(
      get: { viewModel.selection.isDecisionRoute && decisionInspectorVisible },
      set: { decisionInspectorVisible = $0 }
    )
  }

  var decisionItems: [Decision] {
    decisionsRuntime.decisions
  }

  var currentDecisionsRuntime: WorkspaceDecisionRuntime {
    decisionsRuntime
  }

  var currentDecisionFilters: DecisionsSidebarViewModel.FilterState {
    decisionFilters
  }

  var decisionAuditEvents: [SupervisorEvent] {
    decisionsRuntime.auditEvents
  }

  var decisionLiveTick: DecisionLiveTickSnapshot {
    decisionsRuntime.liveTick
  }

  var decisionDetailTabBinding: Binding<DecisionDetailTab> {
    $decisionDetailTab
  }

  var currentDecisionDetailTab: DecisionDetailTab {
    get { decisionDetailTab }
    nonmutating set { decisionDetailTab = newValue }
  }

  var dismissAllVisibleDraftText: String {
    get { dismissAllVisibleDraft }
    nonmutating set { dismissAllVisibleDraft = newValue }
  }

  var currentPendingDismissBatch: DismissBatchSnapshot? {
    get { pendingDismissBatch }
    nonmutating set { pendingDismissBatch = newValue }
  }

  var showsDismissAllVisibleConfirmation: Bool {
    get { showDismissAllVisibleConfirmation }
    nonmutating set { showDismissAllVisibleConfirmation = newValue }
  }

  var currentReopenBatch: ReopenBatchState? {
    get { reopenBatch }
    nonmutating set { reopenBatch = newValue }
  }

  var isDecisionInspectorVisible: Bool {
    get { decisionInspectorVisible }
    nonmutating set { decisionInspectorVisible = newValue }
  }

  public var body: some View {
    @Bindable var viewModel = viewModel
    let displayState = displayState
    let decisionScope = decisionWorkspaceScope
    let splitView = workspaceSplitView(
      displayState: displayState,
      decisionScope: decisionScope,
      selection: $viewModel.selection
    )

    return
      splitView
      .navigationSplitViewStyle(.balanced)
      .toolbar {
        agentTuiNavigationToolbarItems
        sessionToolbarItems
        decisionToolbarItems(decisionScope: decisionScope)
        ToolbarItem(placement: .automatic) {
          Button(action: refresh) {
            Label("Refresh", systemImage: "arrow.clockwise")
          }
          .harnessMCPButton(
            HarnessMonitorAccessibility.agentTuiRefreshButton,
            label: "Refresh workspace"
          )
        }
      }
      .toolbarBaselineOverlay()
      .toolbarBackgroundVisibility(.automatic, for: .windowToolbar)
      .containerBackground(.windowBackground, for: .window)
      .task {
        await prepareWorkspace(viewModel: viewModel)
      }
      .onChange(of: store.pendingWorkspaceSelection) { _, _ in
        consumePendingWorkspaceSelection()
      }
      .onChange(of: workspaceRefreshState) { _, _ in
        refreshWorkspaceAfterDataChange()
      }
      .onChange(of: store.supervisorDecisionRefreshTick) { _, _ in
        handleSupervisorDecisionRefresh()
      }
      .onChange(of: store.supervisorSelectedDecisionID) { _, _ in
        syncSupervisorDecisionRoute(recordHistory: true)
      }
      .onChange(of: store.supervisorObserverFocusTick) { _, _ in
        focusDecisionDesk()
      }
      .onChange(of: store.supervisorPrimaryActionFocusRequestTick) { _, _ in
        focusPrimaryDecisionAction()
      }
      .onChange(of: store.selectedAgentTui?.tuiId) { _, selectedTuiID in
        handleSelectedTuiChange(selectedTuiID, viewModel: viewModel)
      }
      .onChange(of: decisionFilters) { _, _ in
        refreshDecisionWorkspaceSnapshot()
      }
      .onChange(of: viewModel.selection) { oldValue, newValue in
        handleViewSelectionChange(from: oldValue, to: newValue, viewModel: viewModel)
      }
      .onDisappear {
        handleWindowDisappear()
      }
      .acpPermissionPresentation(store: store)
      .confirmationDialog(
        "Dismiss all visible decisions",
        isPresented: $showDismissAllVisibleConfirmation,
        titleVisibility: .visible
      ) {
        TextField(
          "Type \(pendingDismissBatch?.count ?? 0) to confirm",
          text: $dismissAllVisibleDraft
        )
        .harnessMCPTextField(
          HarnessMonitorAccessibility.decisionBulkDismissVisibleInput,
          label: "Dismiss all visible decision confirmation",
          value: dismissAllVisibleDraft
        )
        Button("Dismiss selected visible") {
          Task { await confirmDismissAllVisible() }
        }
        .disabled(dismissAllVisibleDraft != "\(pendingDismissBatch?.count ?? -1)")
        .harnessMCPButton(
          HarnessMonitorAccessibility.decisionBulkDismissVisibleConfirm,
          label: "Dismiss selected visible decisions",
          enabled: dismissAllVisibleDraft == "\(pendingDismissBatch?.count ?? -1)"
        )
        Button("Cancel", role: .cancel) {}
          .harnessMCPButton(
            HarnessMonitorAccessibility.decisionBulkDismissVisibleCancel,
            label: "Cancel dismiss all visible decisions"
          )
      } message: {
        Text(dismissConfirmationMessage)
      }
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiSheet)
  }

  private func workspaceSplitView(
    displayState: AgentTuiDisplayState,
    decisionScope: DecisionWorkspaceScope,
    selection: Binding<WorkspaceSelection>
  ) -> some View {
    NavigationSplitView {
      WorkspaceSidebar(
        store: store,
        selection: selection,
        decisionFilters: $decisionFilters,
        decisionScope: decisionScope,
        currentSessionID: store.selectedSessionID,
        currentSessionTitle: store.selectedSession?.session.title,
        agentTuis: displayState.sortedAgentTuis,
        sessionTitlesByID: displayState.sessionTitlesByID,
        codexRuns: displayState.sortedCodexRuns,
        codexTitlesByID: displayState.codexTitlesByID,
        externalAgents: displayState.externalAgents,
        pendingDecisionAttention: pendingDecisionAttentionByAgentID,
        openPendingDecisions: openPendingDecisions,
        tasks: store.selectedSession?.tasks ?? [],
        refresh: refresh
      )
      .navigationSplitViewColumnWidth(
        min: WorkspaceChromeMetrics.sidebarMinWidth,
        ideal: WorkspaceChromeMetrics.sidebarIdealWidth,
        max: WorkspaceChromeMetrics.sidebarMaxWidth
      )
      .toolbarBaselineFrame(.sidebar)
    } detail: {
      detailColumnContent(decisionScope: decisionScope)
        .inspector(isPresented: decisionInspectorBinding) {
          if viewModel.selection.isDecisionRoute {
            DecisionInspector(
              decision: decisionScope.selectedDecision,
              liveTick: decisionLiveTick
            )
            .inspectorColumnWidth(min: 200, ideal: 220, max: 280)
          }
        }
    }
  }

  private func prepareWorkspace(viewModel: ViewModel) async {
    viewModel.windowNavigation.setHandlers(
      back: { navigateHistoryBack() },
      forward: { navigateHistoryForward() }
    )
    navigationBridge.update(viewModel.windowNavigation)
    await Task.yield()
    async let catalogsLoaded = loadAgentPickerCatalogs()
    let refreshOutcome = await refreshManagedSelections()
    applyManagedSelectionFreshness(refreshOutcome)
    refreshWorkspaceAfterDataChange(afterRefresh: refreshOutcome.didRefreshManagedSelections)
    await reloadDecisions()
    syncSupervisorDecisionRoute(recordHistory: false)
    consumePendingWorkspaceSelection()
    _ = await catalogsLoaded
  }

  private func refreshWorkspaceAfterDataChange(afterRefresh: Bool = false) {
    refreshDisplayState()
    reconcileSheetState(afterRefresh: afterRefresh)
  }

  private func handleSupervisorDecisionRefresh() {
    Task {
      await reloadDecisions()
      syncSupervisorDecisionRoute(recordHistory: false)
    }
  }

  private func handleSelectedTuiChange(
    _ selectedTuiID: String?,
    viewModel: ViewModel
  ) {
    guard let selectedTuiID else {
      return
    }
    if viewModel.selection.terminalID == selectedTuiID,
      let currentSize = selectedSessionTui?.size
    {
      syncTerminalResizeControls(to: currentSize)
      if viewModel.expectedSize == nil {
        viewModel.expectedSize = currentSize
      }
      enforceExpectedSize()
    }
  }

}
