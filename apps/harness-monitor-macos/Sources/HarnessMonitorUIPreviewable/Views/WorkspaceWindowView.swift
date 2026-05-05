import HarnessMonitorKit
import SwiftUI

public struct WorkspaceWindowView: View {
  static let initialDecisionFilters = DecisionsSidebarViewModel.FilterState(
    query: "",
    severities: [],
    scope: .summary
  )

  let store: HarnessMonitorStore
  let keyWindowObserver: KeyWindowObserver?
  let navigationBridge: WorkspaceWindowNavigationBridge
  @State private var sidebarVisibilityExpander = HarnessSidebarVisibilityExpander()
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
  @State private var pendingDismissBatch: WorkspaceDecisionDismissBatchSnapshot?
  @State private var showDismissAllVisibleConfirmation = false
  @State private var reopenBatch: WorkspaceDecisionReopenBatchState?
  @State private var decisionInspectorVisible = false
  @State private var decisionInspectorPreferredVisibility = false
  @State private var columnVisibility: NavigationSplitViewVisibility = .all
  @AppStorage(HarnessMonitorAgentTuiDefaults.submitSendsEnterKey)
  var submitSendsEnter = HarnessMonitorAgentTuiDefaults.submitSendsEnterDefault
  @Environment(\.fontScale)
  private var stateFontScale
  @FocusState private var stateFocusedField: Field?

  @MainActor
  public init(
    store: HarnessMonitorStore,
    keyWindowObserver: KeyWindowObserver? = nil,
    navigationBridge: WorkspaceWindowNavigationBridge = WorkspaceWindowNavigationBridge()
  ) {
    self.store = store
    self.keyWindowObserver = keyWindowObserver
    self.navigationBridge = navigationBridge
    let initialWorkspaceRequest = store.consumePendingWorkspaceSelectionRequest()
    if initialWorkspaceRequest?.resetDecisionFilters == true {
      WorkspaceDecisionFilterDefaults.reset()
    }
    let initialDisplayState = AgentTuiDisplayState(initialWindowStore: store)
    let initialSelection = Self.initialWindowSelection(
      store: store,
      displayState: initialDisplayState,
      pendingRequest: initialWorkspaceRequest
    )
    let initialViewModel = ViewModel(
      selection: initialSelection,
      displayState: initialDisplayState,
      createSessionID: store.selectedSessionID
    )
    if case .create = initialSelection,
      let createEntryPoint = initialWorkspaceRequest?.createEntryPoint
    {
      Self.applyWorkspaceCreateEntryPoint(createEntryPoint, to: initialViewModel)
      let normalizedCreateSessionID = Self.normalizedCreateSessionAnchor(
        initialWorkspaceRequest?.createSessionID
      )
      initialViewModel.pendingCreateSessionID = normalizedCreateSessionID
      if let normalizedCreateSessionID {
        initialViewModel.createSessionID = normalizedCreateSessionID
      }
    }
    Self.applyPreviewCreatePresetIfNeeded(to: initialViewModel)
    _stateViewModel = State(
      wrappedValue: initialViewModel
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

  var startupFocusParticipationEnabled: Bool {
    isStartupFocusParticipationEnabled
  }

  var workspacePreparationComplete: Bool {
    get { hasCompletedInitialWorkspacePreparation }
    nonmutating set { hasCompletedInitialWorkspacePreparation = newValue }
  }

  var startupFocusParticipationActive: Bool {
    get { isStartupFocusParticipationEnabled }
    nonmutating set { isStartupFocusParticipationEnabled = newValue }
  }

  var columnVisibilityBinding: Binding<NavigationSplitViewVisibility> {
    $columnVisibility
  }

  var decisionFiltersBinding: Binding<DecisionsSidebarViewModel.FilterState> {
    $decisionFilters
  }

  func resetDecisionFiltersToInitialState() {
    decisionFilters = Self.initialDecisionFilters
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

  var dismissAllVisibleDraftBinding: Binding<String> {
    $dismissAllVisibleDraft
  }

  var currentPendingDismissBatch: WorkspaceDecisionDismissBatchSnapshot? {
    get { pendingDismissBatch }
    nonmutating set { pendingDismissBatch = newValue }
  }

  var showsDismissAllVisibleConfirmation: Bool {
    get { showDismissAllVisibleConfirmation }
    nonmutating set { showDismissAllVisibleConfirmation = newValue }
  }

  var showDismissAllVisibleConfirmationBinding: Binding<Bool> {
    $showDismissAllVisibleConfirmation
  }

  var currentReopenBatch: WorkspaceDecisionReopenBatchState? {
    get { reopenBatch }
    nonmutating set { reopenBatch = newValue }
  }

  var isDecisionInspectorVisible: Bool {
    decisionInspectorVisible
  }

  var isWorkspaceKeyWindow: Bool {
    keyWindowObserver?.isKey(windowID: HarnessMonitorWindowID.workspace) ?? true
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
    let content = configuredWorkspaceContent(
      pendingSelectionAwareContent(splitView),
      decisionScope: decisionScope,
      viewModel: viewModel
    )

    return
      applyDismissAllVisibleDialog(to: content)
      .navigationTitle(workspaceNavigationTitle(for: viewModel.selection))
      .navigationSubtitle(workspaceNavigationSubtitle(for: viewModel.selection))
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier(HarnessMonitorAccessibility.workspaceWindow)
  }

  private func configuredWorkspaceContent<Content: View>(
    _ splitView: Content,
    decisionScope: DecisionWorkspaceScope,
    viewModel: ViewModel
  ) -> some View {
    splitView
      .navigationSplitViewStyle(.prominentDetail)
      .toolbarBackgroundVisibility(.automatic, for: .windowToolbar)
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
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .task {
        await prepareWorkspace()
      }
      .task(id: store.pendingWorkspaceSelection) {
        _ = consumePendingWorkspaceSelection()
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
      .onChange(of: store.supervisorLiveTickRefreshTick) { _, _ in
        Task { await handleSupervisorLiveTickRefresh() }
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
      .onChange(of: agentLaunchAvailabilitySignal) { _, _ in
        Task { await reloadAgentPickerCatalogsIfPending() }
      }
      .onDisappear {
        hasCompletedInitialWorkspacePreparation = false
        handleWindowDisappear()
        sidebarVisibilityExpander.handler = nil
      }
      .acpPermissionPresentation(store: store)
      .focusedSceneValue(
        \.harnessSidebarVisibilityRequest,
        HarnessSidebarVisibilityRequest(expander: sidebarVisibilityExpander)
      )
      .task {
        let binding = columnVisibilityBinding
        sidebarVisibilityExpander.handler = {
          restoreSidebarVisibility(using: binding)
        }
      }
  }

  @ViewBuilder
  private func pendingSelectionAwareContent<Content: View>(
    _ splitView: Content
  ) -> some View {
    if store.pendingWorkspaceSelection != nil {
      WorkspaceWindowOpeningView()
    } else {
      splitView
    }
  }
}
