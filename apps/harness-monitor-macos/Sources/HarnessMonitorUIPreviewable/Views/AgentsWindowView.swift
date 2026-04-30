import AppKit
import HarnessMonitorKit
import SwiftUI

struct ClickableSwitchStyle: ToggleStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack {
      configuration.label
        .onTapGesture { configuration.isOn.toggle() }
      Toggle("", isOn: configuration.$isOn)
        .toggleStyle(.switch)
        .labelsHidden()
    }
  }
}

private enum WorkspaceChromeMetrics {
  static let sidebarMinWidth: CGFloat = 220
  static let sidebarIdealWidth: CGFloat = 260
  static let sidebarMaxWidth: CGFloat = 380
}

public struct AgentsWindowView: View {
  struct DismissBatchSnapshot: Equatable {
    let ids: [String]
    let count: Int
    let filterSignature: String
    let capturedAt: Date
  }

  struct ReopenBatchState: Equatable {
    let ids: [String]
    let expiresAt: Date
  }

  let store: HarnessMonitorStore
  let navigationBridge: AgentsWindowNavigationBridge
  @Environment(\.openWindow)
  var openWindow
  @State private var stateViewModel: ViewModel
  @State private var decisionsRuntime = DecisionsWindowRuntime()
  @State private var decisionFilters = DecisionsSidebarViewModel.FilterState(
    query: "",
    severities: [],
    scope: .summary
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
    navigationBridge: AgentsWindowNavigationBridge = AgentsWindowNavigationBridge()
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
        displayState: initialDisplayState
      )
    )
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

  var currentDecisionsRuntime: DecisionsWindowRuntime {
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
    let splitView = workspaceSplitView(
      displayState: displayState,
      selection: $viewModel.selection
    )

    return
      splitView
      .navigationSplitViewStyle(.balanced)
      .toolbar {
        agentTuiNavigationToolbarItems
        sessionToolbarItems
        decisionToolbarItems
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
      .onChange(of: store.selectedAgentTuis) { _, _ in
        refreshWorkspaceAfterDataChange()
      }
      .onChange(of: store.selectedCodexRuns) { _, _ in
        refreshWorkspaceAfterDataChange()
      }
      .onChange(of: store.agentTuiUnavailable) { _, _ in
        refreshWorkspaceAfterDataChange()
      }
      .onChange(of: store.codexUnavailable) { _, _ in
        refreshWorkspaceAfterDataChange()
      }
      .onChange(of: store.selectedSession) { _, _ in
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
        .accessibilityIdentifier(HarnessMonitorAccessibility.decisionBulkDismissVisibleInput)
        Button("Dismiss selected visible") {
          Task { await confirmDismissAllVisible() }
        }
        .disabled(dismissAllVisibleDraft != "\(pendingDismissBatch?.count ?? -1)")
        .accessibilityIdentifier(HarnessMonitorAccessibility.decisionBulkDismissVisibleConfirm)
        Button("Cancel", role: .cancel) {}
      } message: {
        Text(dismissConfirmationMessage)
      }
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiSheet)
  }

  private func workspaceSplitView(
    displayState: AgentTuiDisplayState,
    selection: Binding<WorkspaceSelection>
  ) -> some View {
    NavigationSplitView {
      AgentsSidebar(
        store: store,
        selection: selection,
        decisionFilters: $decisionFilters,
        decisions: decisionItems,
        currentSessionID: store.selectedSessionID,
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
      detailColumnContent
        .inspector(isPresented: decisionInspectorBinding) {
          if viewModel.selection.isDecisionRoute {
            DecisionInspector(
              decision: selectedDecision,
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
