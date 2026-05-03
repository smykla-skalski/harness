import AppKit
import HarnessMonitorKit
import SwiftUI

public struct WorkspaceWindowView: View {
  static let initialDecisionFilters = DecisionsSidebarViewModel.FilterState(
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
  let keyWindowObserver: KeyWindowObserver?
  let navigationBridge: WorkspaceWindowNavigationBridge
  @Environment(\.resetFocus)
  private var resetFocus
  @FocusedValue(\.harnessPreservePrimaryContentFocus)
  private var preservesPrimaryContentFocus
  @FocusedValue(\.harnessPrimaryContentResetSuppression)
  private var resetSuppression
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
  @State private var pendingDismissBatch: DismissBatchSnapshot?
  @State private var showDismissAllVisibleConfirmation = false
  @State private var reopenBatch: ReopenBatchState?
  @State private var decisionInspectorVisible = false
  @State private var decisionInspectorPreferredVisibility = false
  @State private var columnVisibility: NavigationSplitViewVisibility = .all
  @State private var primaryContentPagingResponderRequest = 0
  @AppStorage(HarnessMonitorAgentTuiDefaults.submitSendsEnterKey)
  var submitSendsEnter = HarnessMonitorAgentTuiDefaults.submitSendsEnterDefault
  @Environment(\.fontScale)
  private var stateFontScale
  @Namespace private var primaryContentFocusScope
  @FocusState private var stateFocusedField: Field?

  enum PrimaryContentFocusTarget: String {
    case create
    case decisionDetail
    case liveViewport
    case genericDetail
  }

  @MainActor
  public init(
    store: HarnessMonitorStore,
    keyWindowObserver: KeyWindowObserver? = nil,
    navigationBridge: WorkspaceWindowNavigationBridge = WorkspaceWindowNavigationBridge()
  ) {
    self.store = store
    self.keyWindowObserver = keyWindowObserver
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

  var currentPrimaryContentPagingRequest: Int {
    primaryContentPagingResponderRequest
  }

  var currentPrimaryContentFocusScope: Namespace.ID? {
    primaryContentFocusScope
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

  var currentPendingDismissBatch: DismissBatchSnapshot? {
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

  var currentReopenBatch: ReopenBatchState? {
    get { reopenBatch }
    nonmutating set { reopenBatch = newValue }
  }

  var isDecisionInspectorVisible: Bool {
    decisionInspectorVisible
  }

  private var primaryContentSelectionSignature: String {
    switch viewModel.selection {
    case .create:
      "create"
    case .decisions(let sessionID):
      "decisions:\(sessionID ?? "nil")"
    case .decision(let sessionID, let decisionID):
      "decision:\(sessionID ?? "nil"):\(decisionID)"
    case .terminal(let sessionID, let terminalID):
      "terminal:\(sessionID ?? "nil"):\(terminalID)"
    case .codex(let sessionID, let runID):
      "codex:\(sessionID ?? "nil"):\(runID)"
    case .agent(let sessionID, let agentID):
      "agent:\(sessionID ?? "nil"):\(agentID)"
    case .task(let sessionID, let taskID):
      "task:\(sessionID ?? "nil"):\(taskID)"
    }
  }

  private var workspacePrimaryContentFocusResetToken: String {
    [
      String(hasCompletedInitialWorkspacePreparation),
      String(isStartupFocusParticipationEnabled),
      primaryContentSelectionSignature,
      currentPrimaryContentFocusTarget.rawValue,
      keyWindowObserver?.snapshot.routingToken ?? "key=untracked",
    ].joined(separator: "|")
  }

  private var isWorkspaceKeyWindow: Bool {
    keyWindowObserver?.isKey(windowID: HarnessMonitorWindowID.workspace) ?? true
  }

  private var currentResetSuppression: PrimaryContentResetSuppression {
    PrimaryContentResetSuppression(
      preservesPrimaryContentFocus: preservesPrimaryContentFocus == true,
      hasFocusedEditorField: stateFocusedField != nil,
      hasPresentedSheet: store.presentedSheet != nil,
      hasPendingConfirmation: store.pendingConfirmation != nil,
      hasDismissConfirmation: showDismissAllVisibleConfirmation
    )
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
    let content =
      splitView
      .focusScope(primaryContentFocusScope)
      // Workspace is workbench-shaped (sidebar drives detail); main window uses .prominentDetail.
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
      .task(id: workspacePrimaryContentFocusResetToken) {
        await resetPrimaryContentFocusIfNeeded()
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
        sidebarVisibilityExpander.handler = nil
      }
      .acpPermissionPresentation(store: store)
      .focusedSceneValue(\.harnessPrimaryContentResetSuppression, currentResetSuppression)
      .focusedSceneValue(
        \.harnessSidebarVisibilityRequest,
        HarnessSidebarVisibilityRequest(expander: sidebarVisibilityExpander)
      )
      .task {
        let binding = columnVisibilityBinding
        sidebarVisibilityExpander.handler = {
          guard binding.wrappedValue == .detailOnly else { return }
          binding.wrappedValue = .all
          // Capture the workspace contentView synchronously before the async hop so
          // the notification targets this window even if key focus shifts in 50ms.
          // asyncAfter(0.05) gives SwiftUI a full rendering cycle to commit the
          // column-visibility change before VoiceOver re-scans the AX tree.
          let contentView = NSApp.keyWindow?.contentView
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if let contentView {
              NSAccessibility.post(element: contentView, notification: .layoutChanged)
            }
          }
        }
      }

    return
      applyDismissAllVisibleDialog(to: content)
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiSheet)
  }

  @MainActor
  private func resetPrimaryContentFocusIfNeeded() async {
    guard
      hasCompletedInitialWorkspacePreparation,
      isStartupFocusParticipationEnabled,
      isWorkspaceKeyWindow,
      // nil during startup or when window is not key; local fallback is correct in both cases.
      !(resetSuppression ?? currentResetSuppression).isSuppressed
    else {
      return
    }
    await Task.yield()
    guard
      hasCompletedInitialWorkspacePreparation,
      isStartupFocusParticipationEnabled,
      isWorkspaceKeyWindow,
      !(resetSuppression ?? currentResetSuppression).isSuppressed
    else {
      return
    }
    resetFocus(in: primaryContentFocusScope)
    primaryContentPagingResponderRequest += 1
  }
}
