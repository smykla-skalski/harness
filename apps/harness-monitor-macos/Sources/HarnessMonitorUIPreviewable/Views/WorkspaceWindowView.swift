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
  static let decisionInspectorWidth: CGFloat = 260
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
  @State private var isStartupFocusParticipationEnabled = HarnessMonitorUITestEnvironment.isEnabled
  @State private var hasCompletedInitialWorkspacePreparation = false
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
  @State private var decisionInspectorPreferredVisibility = false
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
    decisionInspectorVisible
  }

  func toggleDecisionInspector() {
    setDecisionInspectorVisible(!decisionInspectorVisible)
  }

  func restoreDecisionInspectorForDecisionRoute() {
    decisionInspectorVisible = decisionInspectorPreferredVisibility
  }

  func hideDecisionInspectorForNonDecisionRoute() {
    decisionInspectorVisible = false
  }

  private func setDecisionInspectorVisible(_ isVisible: Bool) {
    decisionInspectorVisible = isVisible
    decisionInspectorPreferredVisibility = isVisible
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
            label: "Refresh workspace",
            pressAction: refresh
          )
        }
      }
      .toolbarBaselineOverlay()
      .toolbarBackgroundVisibility(.automatic, for: .windowToolbar)
      .containerBackground(.windowBackground, for: .window)
      .task {
        await prepareWorkspace()
      }
      .onChange(of: store.pendingWorkspaceSelection) { _, _ in
        consumePendingWorkspaceSelection()
      }
      .onChange(of: workspaceRefreshState) { _, _ in
        guard hasCompletedInitialWorkspacePreparation else {
          return
        }
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
        guard hasCompletedInitialWorkspacePreparation else {
          return
        }
        handleSelectedTuiChange(selectedTuiID, viewModel: viewModel)
      }
      .onChange(of: decisionFilters) { _, _ in
        refreshDecisionWorkspaceSnapshot()
      }
      .onChange(of: viewModel.selection) { oldValue, newValue in
        handleViewSelectionChange(from: oldValue, to: newValue, viewModel: viewModel)
      }
      .onDisappear {
        hasCompletedInitialWorkspacePreparation = false
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
          enabled: dismissAllVisibleDraft == "\(pendingDismissBatch?.count ?? -1)",
          pressAction: { Task { await confirmDismissAllVisible() } }
        )
        Button("Cancel", role: .cancel) {}
          .harnessMCPButton(
            HarnessMonitorAccessibility.decisionBulkDismissVisibleCancel,
            label: "Cancel dismiss all visible decisions",
            pressAction: { showDismissAllVisibleConfirmation = false }
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
        isStartupFocusParticipationEnabled: isStartupFocusParticipationEnabled,
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
      detailSplitViewContent(decisionScope: decisionScope)
    }
  }

  @ViewBuilder
  private func detailSplitViewContent(
    decisionScope: DecisionWorkspaceScope
  ) -> some View {
    HStack(spacing: 0) {
      detailColumnContent(decisionScope: decisionScope)
        .frame(maxWidth: .infinity, maxHeight: .infinity)

      if viewModel.selection.isDecisionRoute, isDecisionInspectorVisible {
        Divider()
        DecisionInspector(
          decision: decisionScope.selectedDecision,
          liveTick: decisionLiveTick
        )
        .frame(
          width: WorkspaceChromeMetrics.decisionInspectorWidth,
          alignment: .topLeading
        )
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(.windowBackground)
      }
    }
  }

  private func prepareWorkspace() async {
    hasCompletedInitialWorkspacePreparation = false
    viewModel.windowNavigation.setHandlers(
      back: { navigateHistoryBack() },
      forward: { navigateHistoryForward() }
    )
    await Task.yield()
    await loadAgentPickerCatalogs()
    resolveInitialWorkspaceSelection()
    await Task.yield()
    guard !Task.isCancelled else {
      return
    }
    hasCompletedInitialWorkspacePreparation = true
    enableStartupFocusParticipation()
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

  private func enableStartupFocusParticipation() {
    guard !isStartupFocusParticipationEnabled else {
      return
    }
    isStartupFocusParticipationEnabled = true
  }

}
