import HarnessMonitorKit
import SwiftUI

public struct TaskBoardOverviewView: View {
  let snapshot: TaskBoardInboxSnapshot
  let taskBoardItems: [TaskBoardItem]
  let store: HarnessMonitorStore?
  let orchestratorStatus: TaskBoardOrchestratorStatus?
  let evaluationSummary: TaskBoardEvaluationSummary?
  let taskBoardSessionID: String?
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
  @State private var draggedCardIDs: [TaskBoardCardID] = []
  @State private var dropCandidateLanes: Set<TaskBoardInboxLane> = []
  @State private var taskBoardSelectionDispatcher = TaskBoardSelectionDispatcher()
  @State private var relativeTimeClock = TaskBoardRelativeTimeClock()
  @State private var localHostRoutingState = TaskBoardLocalHostRoutingState()
  @AppStorage(TaskBoardEvaluatePreferences.dryRunStorageKey)
  var evaluateDryRun = TaskBoardEvaluatePreferences.defaultDryRun
  @State private var evaluatePreviewState = TaskBoardEvaluatePreviewState()
  @State private var pendingLiveOperation: TaskBoardOverviewLiveOperation?
  @AppStorage(TaskBoardLaneCollapsePreferences.storageKey)
  var laneCollapsePreferencesRawValue = TaskBoardLaneCollapsePreferences.emptyRawValue
  @AppStorage(TaskBoardLaneAppearancePreferences.storageKey)
  var laneAppearancePreferencesRawValue = TaskBoardLaneAppearancePreferences.emptyRawValue
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

  var laneMetrics: TaskBoardLaneMetrics { TaskBoardLaneMetrics(fontScale: fontScale) }

  var laneStripSizing: TaskBoardLaneStripSizing {
    TaskBoardLaneStripSizing(
      minColumnWidth: laneMetrics.laneWidth,
      spacing: metrics.columnSpacing,
      collapsedColumnWidth: laneMetrics.laneCollapsedWidth
    )
  }

  var currentPresentation: TaskBoardOverviewPresentation { cachedPresentation }

  var liveInboxItemsValue: TaskBoardLiveInboxItems { liveInboxItems }

  public init(
    snapshot: TaskBoardInboxSnapshot,
    taskBoardItems: [TaskBoardItem] = [],
    store: HarnessMonitorStore? = nil,
    orchestratorStatus: TaskBoardOrchestratorStatus? = nil,
    evaluationSummary: TaskBoardEvaluationSummary? = nil,
    taskBoardSessionID: String? = nil,
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
    self.orchestratorStatus = orchestratorStatus
    self.evaluationSummary = evaluationSummary
    self.taskBoardSessionID = taskBoardSessionID
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
    .environment(
      \.taskBoardLaneAppearance,
      TaskBoardLaneAppearance(rawValue: laneAppearancePreferencesRawValue)
    )
    .harnessFocusedSceneValue(\.harnessTaskBoardCommandFocus, taskBoardCommandFocus)
    .taskBoardSelectionForwardDeleteShortcut(taskBoardCommandFocus?.selection)
    .taskBoardCardPreferences(projectLabelResolver: cachedPresentation.projectLabelResolver)
    .environment(relativeTimeClock)
    .sheet(item: taskBoardManagementSheet) { taskBoardManagementSheet in
      taskBoardManagementSheetContent(taskBoardManagementSheet)
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
    .onChange(of: taskBoardSelectionDispatcher.deleteRequestGeneration) {
      requestDeleteSelectedTaskBoardCards()
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
      scopeSessionID: taskBoardSessionID
    )
  }

  var selectionModelValue: TaskBoardCardSelectionModel {
    selectionModel
  }

  var draggedCardIDsValue: [TaskBoardCardID] {
    get { draggedCardIDs }
    nonmutating set { draggedCardIDs = newValue }
  }

  var dropCandidateLanesValue: Set<TaskBoardInboxLane> {
    get { dropCandidateLanes }
    nonmutating set { dropCandidateLanes = newValue }
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

extension TaskBoardOverviewView {
  func evaluationSummaryRow(_ summary: TaskBoardEvaluationSummary) -> some View {
    Group {
      if evaluationSummaryFitsHorizontally {
        HStack(spacing: HarnessMonitorTheme.spacingSM) {
          evaluationSummaryContent(summary)
        }
      } else {
        VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
          evaluationSummaryContent(summary)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .onGeometryChange(for: CGFloat.self) { proxy in
      proxy.size.width
    } action: { width in
      let next = width >= 420
      if evaluationSummaryFitsHorizontally != next {
        evaluationSummaryFitsHorizontally = next
      }
    }
    .accessibilityIdentifier("harness.task-board.evaluation-summary")
  }

  @MainActor
  func rebuildPresentation(input: TaskBoardOverviewPresentationInput) async {
    guard !Task.isCancelled else { return }
    presentationGeneration &+= 1
    let generation = presentationGeneration
    let presentation = await presentationWorker.compute(input: input)
    guard !Task.isCancelled, presentationGeneration == generation else {
      return
    }
    if cachedPresentation != presentation {
      cachedPresentation = presentation
      selectionModel.updateVisibleIDs(presentation.orderedCardIDs)
    }
  }
}
