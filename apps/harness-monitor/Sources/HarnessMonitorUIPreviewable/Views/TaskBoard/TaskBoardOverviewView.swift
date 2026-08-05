import Foundation
import HarnessMonitorKit
import SwiftUI

public struct TaskBoardOverviewView: View {
  let snapshot: TaskBoardInboxSnapshot
  let taskBoardItems: [TaskBoardItem]
  let store: HarnessMonitorStore?
  let navigationHistory: GlobalWindowNavigationHistory?
  let orchestratorStatus: TaskBoardOrchestratorStatus?
  let evaluationSummary: TaskBoardEvaluationSummary?
  let taskBoardSessionID: String?
  let isRouteVisible: Bool
  let contentHorizontalPadding: CGFloat
  let fillsAvailableHeight: Bool
  let showsOperationsPanel: Bool
  let isCommandFocusActive: Bool
  let operationsInspectorFocus: TaskBoardOperationsInspectorFocus?
  let decisions: [Decision]
  let decisionsByID: [String: Decision]
  let decisionItems: [DecisionPresentationItem]
  let isActionInFlight: Bool
  let actions: TaskBoardOverviewActions
  @Environment(\.fontScale)
  var fontScale
  @Environment(\.scenePhase)
  var scenePhase
  @Environment(\.openURL)
  var openURL
  @Environment(\.openWindow)
  var openWindow
  @State private var selectionModel = TaskBoardCardSelectionModel()
  @State private var evaluationSummaryFitsHorizontally = true
  @State private var presentationWorker = TaskBoardOverviewPresentationWorker()
  @State private var cachedPresentation = TaskBoardOverviewPresentation.empty
  @State private var liveInboxItems = TaskBoardLiveInboxItems()
  @State private var presentationGeneration: UInt64 = 0
  @State private var cardDragRuntime = TaskBoardCardDragRuntime()
  @State private var nativeListCoordinator = TaskBoardNativeListCoordinator()
  @State private var cardGapModel = TaskBoardCardGapModel()
  @State private var optimisticDropDeliveredAt: TimeInterval?
  @State private var latestOptimisticSettleMilliseconds: Int?
  /// One commit per drag: the row dropDestination and the whole-lane fallback can both
  /// fire for the same drop, so the first commit wins. Reset at drag start.
  @State private var didCommitDrop = false
  @State private var laneRevealCoordinator = TaskBoardLaneRevealCoordinator()
  @State private var taskBoardSelectionDispatcher = TaskBoardSelectionDispatcher()
  @State private var relativeTimeClock = TaskBoardRelativeTimeClock()
  @State private var localHostRoutingState = TaskBoardLocalHostRoutingState()
  @State private var evaluatePreviewState = TaskBoardEvaluatePreviewState()
  @State private var pendingLiveOperation: TaskBoardOverviewLiveOperation?
  @AppStorage(TaskBoardLaneCollapsePreferences.storageKey)
  var laneCollapsePreferencesRawValue = TaskBoardLaneCollapsePreferences.emptyRawValue
  @AppStorage(TaskBoardLaneAppearancePreferences.storageKey)
  var laneAppearancePreferencesRawValue = TaskBoardLaneAppearancePreferences.emptyRawValue
  @AppStorage(TaskBoardFilterPreferences.storageKey)
  var filterPreferencesRawValue = TaskBoardFilterPreferences.emptyRawValue
  /// What the field holds right now. The filter is a view someone keeps, so it
  /// is stored; a search is something they are in the middle of, so it is not.
  @State private var searchText = ""
  /// What the board is narrowed by: the field's text once the keystrokes have
  /// settled, so a half-typed word never empties the lanes on the way through.
  @State private var appliedSearchText = ""
  var captionSemibold: Font {
    HarnessMonitorTextSize.scaledFont(.caption.weight(.semibold), by: fontScale)
  }
  var bodyFont: Font {
    HarnessMonitorTextSize.scaledFont(.body, by: fontScale)
  }
  var titleHeaderFont: Font {
    HarnessMonitorTextSize.scaledFont(
      .system(.title3, design: .rounded, weight: .semibold),
      by: fontScale
    )
  }

  var metrics: TaskBoardOverviewMetrics { TaskBoardOverviewMetrics(fontScale: fontScale) }

  var evaluateDryRun: Bool {
    orchestratorStatus?.settings.dryRunDefault ?? true
  }

  var laneMetrics: TaskBoardLaneMetrics { TaskBoardLaneMetrics(fontScale: fontScale) }

  var laneStripSizing: TaskBoardLaneStripSizing {
    TaskBoardLaneStripSizing(
      minColumnWidth: laneMetrics.laneWidth,
      spacing: metrics.columnSpacing,
      collapsedColumnWidth: laneMetrics.laneCollapsedWidth
    )
  }

  var currentPresentation: TaskBoardOverviewPresentation { cachedPresentation }

  var evaluationSummaryFitsHorizontallyValue: Bool {
    get { evaluationSummaryFitsHorizontally }
    nonmutating set { evaluationSummaryFitsHorizontally = newValue }
  }

  func applyImmediateTaskBoardPresentation(_ presentation: TaskBoardOverviewPresentation) {
    // Reject any older actor result already in flight. The next task keyed by
    // the updated input remains authoritative and will reconcile this value.
    presentationGeneration &+= 1
    guard cachedPresentation != presentation else { return }
    cachedPresentation = presentation
    selectionModel.updateVisibleIDs(presentation.orderedCardIDs)
  }

  func applyImmediateTaskBoardPositionProjection() {
    guard let store else { return }
    let projection = currentPresentation.replacingTaskBoardItemsForImmediatePosition(
      store.globalTaskBoardItems,
      scopeSessionID: taskBoardSessionID
    )
    applyImmediateTaskBoardPresentation(projection)
    traceTaskBoardCardDrag("optimistic presentation applied")
  }

  func beginOptimisticSettleMeasurement() {
    guard HarnessMonitorUITestEnvironment.accessibilityMarkersEnabled else { return }
    optimisticDropDeliveredAt = ProcessInfo.processInfo.systemUptime
    latestOptimisticSettleMilliseconds = nil
  }

  func finishOptimisticSettleMeasurement() {
    guard let deliveredAt = optimisticDropDeliveredAt else { return }
    latestOptimisticSettleMilliseconds = Int(
      ((ProcessInfo.processInfo.systemUptime - deliveredAt) * 1_000).rounded()
    )
    optimisticDropDeliveredAt = nil
  }

  func cancelOptimisticSettleMeasurement() {
    optimisticDropDeliveredAt = nil
    latestOptimisticSettleMilliseconds = nil
  }

  var liveInboxItemsValue: TaskBoardLiveInboxItems { liveInboxItems }

  var searchTextValue: String { searchText }

  var appliedSearchTextValue: String {
    get { appliedSearchText }
    nonmutating set { appliedSearchText = newValue }
  }

  var presentationGenerationValue: UInt64 {
    get { presentationGeneration }
    nonmutating set { presentationGeneration = newValue }
  }

  var presentationWorkerValue: TaskBoardOverviewPresentationWorker { presentationWorker }

  var cachedPresentationValue: TaskBoardOverviewPresentation {
    get { cachedPresentation }
    nonmutating set { cachedPresentation = newValue }
  }

  public init(
    snapshot: TaskBoardInboxSnapshot,
    taskBoardItems: [TaskBoardItem] = [],
    store: HarnessMonitorStore? = nil,
    navigationHistory: GlobalWindowNavigationHistory? = nil,
    orchestratorStatus: TaskBoardOrchestratorStatus? = nil,
    evaluationSummary: TaskBoardEvaluationSummary? = nil,
    taskBoardSessionID: String? = nil,
    isRouteVisible: Bool = true,
    contentHorizontalPadding: CGFloat = 24,
    fillsAvailableHeight: Bool = false,
    showsOperationsPanel: Bool = true,
    isCommandFocusActive: Bool = true,
    operationsInspectorFocus: TaskBoardOperationsInspectorFocus? = nil,
    decisions: [Decision] = [],
    isActionInFlight: Bool = false,
    actions: TaskBoardOverviewActions = TaskBoardOverviewActions(store: nil, scope: .dashboard),
    decisionItems: [DecisionPresentationSnapshot],
    decisionsByID: [String: Decision]
  ) {
    self.snapshot = snapshot
    self.taskBoardItems = taskBoardItems
    self.store = store
    self.navigationHistory = navigationHistory
    self.orchestratorStatus = orchestratorStatus
    self.evaluationSummary = evaluationSummary
    self.taskBoardSessionID = taskBoardSessionID
    self.isRouteVisible = isRouteVisible
    self.contentHorizontalPadding = contentHorizontalPadding
    self.fillsAvailableHeight = fillsAvailableHeight
    self.showsOperationsPanel = showsOperationsPanel
    self.isCommandFocusActive = isCommandFocusActive
    self.operationsInspectorFocus = operationsInspectorFocus
    self.decisions = decisions
    self.decisionsByID = decisionsByID
    self.decisionItems = decisionItems
    self.isActionInFlight = isActionInFlight
    self.actions = actions
  }

  public var body: some View {
    let presentationInput = synchronizedPresentationInput
    let dashboardNavigationTaskID = DashboardTaskBoardNavigationTaskID(
      requestID: navigationHistory?.pendingDashboardTaskBoardRestoreRequest?.requestID,
      isRouteVisible: isRouteVisible,
      presentationInput: presentationInput
    )
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
      boardChrome
      taskBoardDetailRow { boardSection }
        .frame(maxHeight: fillsAvailableHeight ? .infinity : nil)
    }
    .frame(
      maxWidth: .infinity,
      maxHeight: fillsAvailableHeight ? .infinity : nil,
      alignment: fillsAvailableHeight ? .topLeading : .leading
    )
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("harness.task-board.overview")
    .overlay {
      if HarnessMonitorUITestEnvironment.accessibilityMarkersEnabled {
        AccessibilityTextMarker(
          identifier: HarnessMonitorAccessibility.taskBoardOptimisticSettle,
          text: latestOptimisticSettleMilliseconds.map(String.init) ?? "pending"
        )
      }
    }
    .environment(
      \.taskBoardLaneAppearance,
      TaskBoardLaneAppearance(rawValue: laneAppearancePreferencesRawValue)
    )
    .harnessFocusedSceneValue(\.harnessTaskBoardCommandFocus, taskBoardCommandFocus)
    .taskBoardSelectionShortcuts(taskBoardCommandFocus?.selection)
    .taskBoardCardPreferences(projectLabelResolver: cachedPresentation.projectLabelResolver)
    .environment(relativeTimeClock)
    .sheet(item: taskBoardManagementSheet) { taskBoardManagementSheet in
      taskBoardManagementSheetContent(taskBoardManagementSheet)
    }
    .onDisappear {
      clearTransientCardDragState()
    }
    .onChange(of: isCommandFocusActive) { _, isActive in
      if !isActive {
        clearTransientCardDragState()
      }
    }
    .onChange(of: isActionInFlight) { _, isInFlight in
      if isInFlight {
        clearTransientCardDragState()
      }
    }
    .onChange(of: cachedPresentation.orderedCardIDs) {
      finishOptimisticSettleMeasurement()
    }
    .onChange(of: scenePhase) { _, newPhase in
      if newPhase != .active {
        clearTransientCardDragState()
      }
    }
    .onKeyPress(.escape, phases: .down) { _ in
      cancelActiveCardDrag() ? .handled : .ignored
    }
    .task {
      await relativeTimeClock.run()
    }
    .task(id: store?.contentUI.dashboard.connectionState == .online) {
      updateLocalHostRouting()
    }
    .task(id: presentationInput) {
      await rebuildPresentation(input: presentationInput)
    }
    .task(id: searchText) {
      await applySearchTextWhenSettled()
    }
    .onChange(of: taskBoardSelectionDispatcher.requestGeneration) {
      handleTaskBoardSelectionRequest(taskBoardSelectionDispatcher.latestRequest)
    }
    .task(id: dashboardNavigationTaskID) {
      await applyPendingDashboardTargetIfReady()
    }
    .confirmationDialog(
      pendingLiveOperationValue?.title ?? "Run live task-board operation?",
      isPresented: pendingLiveOperationIsPresented,
      presenting: pendingLiveOperationValue
    ) { operation in
      Button(operation.actionTitle, role: .destructive) {
        pendingLiveOperationValue = nil
        performLiveOperation(operation)
      }
      .disabled(isActionInFlight)
      Button("Cancel", role: .cancel) {}
    } message: { operation in
      Text(operation.message)
    }
  }

  @MainActor private var synchronizedPresentationInput: TaskBoardOverviewPresentationInput {
    // Event handlers installed by this body must validate against the same
    // snapshot immediately, before the off-main presentation worker runs.
    liveInboxItems.replaceIfChanged(with: snapshot.items)
    return TaskBoardOverviewPresentationInput(
      snapshot: snapshot,
      taskBoardItems: taskBoardItems,
      decisionItems: decisionItems,
      scopeSessionID: taskBoardSessionID,
      configuredRepositories: orchestratorStatus?.settings.githubInbox.repositories,
      taskBoardItemsSnapshotAvailable: store?.contentUI.dashboard
        .taskBoardItemsSnapshotAvailable == true || !taskBoardItems.isEmpty,
      orchestratorStatus: orchestratorStatus,
      latestEvaluation: evaluationSummary,
      latestEvaluationBaselineRunID: store?.contentUI.dashboard
        .taskBoardEvaluationBaselineRunID,
      localHostProjectTypes: localHostRoutingStateValue.projectTypes,
      taskBoardProjects: store?.globalTaskBoardProjects ?? [],
      filters: boardFilters,
      searchText: boardSearchText
    )
  }

  /// The filter belongs to the board proper. A session window embeds a view
  /// already scoped to that session, so narrowing it again by a filter someone
  /// set on the dashboard would hide work with no control in sight to undo it.
  var boardFilters: TaskBoardFilterState {
    guard taskBoardSessionID == nil else {
      return .init()
    }
    return TaskBoardFilterPreferences.state(from: filterPreferencesRawValue)
  }

  var boardFiltersBinding: Binding<TaskBoardFilterState> {
    Binding(
      get: { boardFilters },
      set: { filterPreferencesRawValue = TaskBoardFilterPreferences.rawValue(for: $0) }
    )
  }

  /// Scoped the same way the filter is, and for the same reason.
  var boardSearchText: String {
    taskBoardSessionID == nil ? appliedSearchText : ""
  }

  /// What the field holds, which leads the applied text by a keystroke or two.
  var boardSearchFieldText: String { searchText }

  var boardSearchTextBinding: Binding<String> {
    Binding(
      get: { searchText },
      set: { searchText = $0 }
    )
  }

  var selectionModelValue: TaskBoardCardSelectionModel {
    selectionModel
  }

  var draggedCardIDsValue: [TaskBoardCardID] {
    cardDragRuntime.cardIDs
  }

  var dropCandidateLanesValue: Set<TaskBoardInboxLane> {
    cardDragRuntime.candidateLanes
  }

  var cardDragRuntimeValue: TaskBoardCardDragRuntime {
    cardDragRuntime
  }

  var nativeListCoordinatorValue: TaskBoardNativeListCoordinator {
    nativeListCoordinator
  }

  var cardGapModelValue: TaskBoardCardGapModel {
    cardGapModel
  }

  var didCommitDropValue: Bool { didCommitDrop }
  func markDropCommitted() { didCommitDrop = true }
  func resetDropCommit() { didCommitDrop = false }

  var laneRevealCoordinatorValue: TaskBoardLaneRevealCoordinator {
    laneRevealCoordinator
  }

  var taskBoardSelectionDispatcherValue: TaskBoardSelectionDispatcher {
    taskBoardSelectionDispatcher
  }

  var evaluatePreviewSummaryValue: TaskBoardEvaluationSummary? {
    get { evaluatePreviewState.summary }
    nonmutating set { evaluatePreviewState.summary = newValue }
  }

  var evaluatePreviewStateValue: TaskBoardEvaluatePreviewState {
    evaluatePreviewState
  }

  var localHostRoutingStateValue: TaskBoardLocalHostRoutingState {
    localHostRoutingState
  }

  var pendingLiveOperationValue: TaskBoardOverviewLiveOperation? {
    get { pendingLiveOperation }
    nonmutating set { pendingLiveOperation = newValue }
  }

  var pendingLiveOperationBinding: Binding<TaskBoardOverviewLiveOperation?> {
    Binding(
      get: { pendingLiveOperationValue },
      set: { pendingLiveOperationValue = $0 }
    )
  }

  var laneCollapsePreferencesRawValueBinding: Binding<String> {
    Binding(
      get: { laneCollapsePreferencesRawValue },
      set: { laneCollapsePreferencesRawValue = $0 }
    )
  }
}
