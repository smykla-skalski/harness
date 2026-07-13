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
  let onOpenItem: (TaskBoardInboxItem) -> Void
  let onOpenTaskBoardItem: (TaskBoardItem) -> Void
  let onMoveInboxItems: (([TaskBoardInboxStatusUpdate]) -> Void)?
  let onMoveTaskBoardItems: (([TaskBoardItemStatusUpdate]) -> Void)?
  let onOpenDecision: (Decision) -> Void
  let onCreateTaskBoardItem: ((TaskBoardCreateItemRequest, TaskBoardStatus) -> Void)?
  let onUpdateTaskBoardItem: ((String, TaskBoardUpdateItemRequest) -> Void)?
  let onDeleteTaskBoardItem: ((TaskBoardItem) -> Void)?
  let onDeleteTaskBoardTargets: (([TaskBoardDeletionTarget]) -> Void)?
  let onEvaluateTaskBoard: (() -> Void)?
  let onEvaluateTaskBoardItem: ((TaskBoardItem) -> Void)?
  let onBeginTaskBoardPlan: ((TaskBoardItem) -> Void)?
  let onSubmitTaskBoardPlan: ((TaskBoardItem, String) -> Void)?
  let onApproveTaskBoardPlan: ((TaskBoardItem, String, String?) -> Void)?
  let onRevokeTaskBoardPlan: ((TaskBoardItem) -> Void)?
  let onRefreshTaskBoard: (() -> Void)?
  let onStartTaskBoardOrchestrator: (() -> Void)?
  let onStopTaskBoardOrchestrator: (() -> Void)?
  let onRunTaskBoardOrchestratorOnce: ((TaskBoardOrchestratorRunOnceRequest) -> Void)?
  @Environment(\.fontScale)
  var fontScale
  @Environment(\.openURL)
  var openURL
  @Environment(\.openWindow)
  var openWindow
  @State private var selectedTaskBoardItemID: String?
  @State private var isCreatingTaskBoardItem = false
  @State private var evaluationSummaryFitsHorizontally = true
  @State private var presentationWorker = TaskBoardOverviewPresentationWorker()
  @State private var cachedPresentation = TaskBoardOverviewPresentation.empty
  @State private var presentationGeneration: UInt64 = 0
  @State private var cardSelection = TaskBoardCardSelectionState()
  @State private var draggedCardIDs: [TaskBoardCardID] = []
  @State private var taskBoardSelectionDispatcher = TaskBoardSelectionDispatcher()
  @State private var relativeTimeClock = TaskBoardRelativeTimeClock()
  @AppStorage(TaskBoardEvaluatePreferences.dryRunStorageKey)
  var evaluateDryRun = TaskBoardEvaluatePreferences.defaultDryRun
  @State private var evaluatePreviewSummary: TaskBoardEvaluationSummary?
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

  var presentationInput: TaskBoardOverviewPresentationInput {
    TaskBoardOverviewPresentationInput(
      snapshot: snapshot,
      taskBoardItems: taskBoardItems,
      decisionItems: decisionItems,
      scopeSessionID: taskBoardSessionID
    )
  }

  var currentPresentation: TaskBoardOverviewPresentation { cachedPresentation }

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
    onOpenItem: @escaping (TaskBoardInboxItem) -> Void = { _ in },
    onOpenTaskBoardItem: @escaping (TaskBoardItem) -> Void = { _ in },
    onMoveInboxItems: (([TaskBoardInboxStatusUpdate]) -> Void)? = nil,
    onMoveTaskBoardItems: (([TaskBoardItemStatusUpdate]) -> Void)? = nil,
    onOpenDecision: @escaping (Decision) -> Void = { _ in },
    onCreateTaskBoardItem: ((TaskBoardCreateItemRequest, TaskBoardStatus) -> Void)? = nil,
    onUpdateTaskBoardItem: ((String, TaskBoardUpdateItemRequest) -> Void)? = nil,
    onDeleteTaskBoardItem: ((TaskBoardItem) -> Void)? = nil,
    onDeleteTaskBoardTargets: (([TaskBoardDeletionTarget]) -> Void)? = nil,
    onEvaluateTaskBoard: (() -> Void)? = nil,
    onEvaluateTaskBoardItem: ((TaskBoardItem) -> Void)? = nil,
    onBeginTaskBoardPlan: ((TaskBoardItem) -> Void)? = nil,
    onSubmitTaskBoardPlan: ((TaskBoardItem, String) -> Void)? = nil,
    onApproveTaskBoardPlan: ((TaskBoardItem, String, String?) -> Void)? = nil,
    onRevokeTaskBoardPlan: ((TaskBoardItem) -> Void)? = nil,
    onRefreshTaskBoard: (() -> Void)? = nil,
    onStartTaskBoardOrchestrator: (() -> Void)? = nil,
    onStopTaskBoardOrchestrator: (() -> Void)? = nil,
    onRunTaskBoardOrchestratorOnce: ((TaskBoardOrchestratorRunOnceRequest) -> Void)? = nil,
    decisionItems: [DecisionPresentationSnapshot]? = nil,
    decisionsByID: [String: Decision]? = nil
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
    self.decisionsByID =
      decisionsByID ?? Dictionary(uniqueKeysWithValues: decisions.map { ($0.id, $0) })
    self.decisionItems = decisionItems ?? decisions.map(DecisionPresentationItem.init)
    self.isActionInFlight = isActionInFlight
    self.onOpenItem = onOpenItem
    self.onOpenTaskBoardItem = onOpenTaskBoardItem
    self.onMoveInboxItems = onMoveInboxItems
    self.onMoveTaskBoardItems = onMoveTaskBoardItems
    self.onOpenDecision = onOpenDecision
    self.onCreateTaskBoardItem = onCreateTaskBoardItem
    self.onUpdateTaskBoardItem = onUpdateTaskBoardItem
    self.onDeleteTaskBoardItem = onDeleteTaskBoardItem
    self.onDeleteTaskBoardTargets = onDeleteTaskBoardTargets
    self.onEvaluateTaskBoard = onEvaluateTaskBoard
    self.onEvaluateTaskBoardItem = onEvaluateTaskBoardItem
    self.onBeginTaskBoardPlan = onBeginTaskBoardPlan
    self.onSubmitTaskBoardPlan = onSubmitTaskBoardPlan
    self.onApproveTaskBoardPlan = onApproveTaskBoardPlan
    self.onRevokeTaskBoardPlan = onRevokeTaskBoardPlan
    self.onRefreshTaskBoard = onRefreshTaskBoard
    self.onStartTaskBoardOrchestrator = onStartTaskBoardOrchestrator
    self.onStopTaskBoardOrchestrator = onStopTaskBoardOrchestrator
    self.onRunTaskBoardOrchestratorOnce = onRunTaskBoardOrchestratorOnce
  }

  public var body: some View {
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
    .task(id: presentationInput) {
      await rebuildPresentation(input: presentationInput)
    }
    .onChange(of: taskBoardSelectionDispatcher.deleteRequestGeneration) {
      requestDeleteSelectedTaskBoardCards()
    }
  }

  var selectedTaskBoardItemIDValue: String? {
    get { selectedTaskBoardItemID }
    nonmutating set { selectedTaskBoardItemID = newValue }
  }

  var isCreatingTaskBoardItemValue: Bool {
    get { isCreatingTaskBoardItem }
    nonmutating set { isCreatingTaskBoardItem = newValue }
  }

  var cardSelectionValue: TaskBoardCardSelectionState {
    get { cardSelection }
    nonmutating set { cardSelection = newValue }
  }

  var draggedCardIDsValue: [TaskBoardCardID] {
    get { draggedCardIDs }
    nonmutating set { draggedCardIDs = newValue }
  }

  var taskBoardSelectionDispatcherValue: TaskBoardSelectionDispatcher {
    taskBoardSelectionDispatcher
  }

  var evaluatePreviewSummaryValue: TaskBoardEvaluationSummary? {
    get { evaluatePreviewSummary }
    nonmutating set { evaluatePreviewSummary = newValue }
  }
}

extension TaskBoardOverviewView {
  @ViewBuilder var boardChrome: some View {
    if hasRouteContent || store != nil {
      if let orchestratorStatus {
        taskBoardDetailRow {
          TaskBoardOrchestratorSummaryView(
            status: orchestratorStatus,
            latestEvaluation: evaluationSummary,
            isActionInFlight: isActionInFlight,
            onStart: onStartTaskBoardOrchestrator,
            onStop: onStopTaskBoardOrchestrator,
            onRunOnce: runOrchestratorOnce
          )
        }
      } else if let evaluationSummary {
        taskBoardDetailRow { evaluationSummaryRow(evaluationSummary) }
      }
    }
    if let evaluatePreviewSummaryValue {
      taskBoardDetailRow { evaluatePreviewRow(evaluatePreviewSummaryValue) }
    }
    taskBoardDetailRow { headerTitle }
    if showsOperationsPanel, let store {
      taskBoardDetailRow {
        TaskBoardOperationsPanel(store: store, taskBoardItems: cachedPresentation.taskBoardItems)
      }
    }
  }

  var headerTitle: some View {
    Label("Board", systemImage: "rectangle.3.group")
      .font(titleHeaderFont)
      .accessibilityAddTraits(.isHeader)
  }

  var headerActions: some View {
    HStack(spacing: HarnessMonitorTheme.spacingSM) {
      headerActionButtons
    }
    .fixedSize(horizontal: true, vertical: false)
  }

  var boardAccessoryRow: some View {
    HStack(alignment: .center, spacing: HarnessMonitorTheme.spacingMD) {
      if hasAggregateSummary {
        aggregateSummaryRow
      }
      if hasAggregateSummary && hasHeaderActions {
        Spacer(minLength: HarnessMonitorTheme.spacingMD)
      }
      if hasHeaderActions {
        headerActions
      }
    }
  }

  var hasHeaderActions: Bool {
    onCreateTaskBoardItem != nil || onEvaluateTaskBoard != nil || onRefreshTaskBoard != nil
  }

  @ViewBuilder var headerActionButtons: some View {
    if onCreateTaskBoardItem != nil {
      Button {
        startTaskBoardItemCreation()
      } label: {
        Label("New Item", systemImage: "plus.circle")
          .font(captionSemibold)
      }
      .frame(minHeight: metrics.controlMinHeight)
      .harnessActionButtonStyle(variant: .bordered, tint: HarnessMonitorTheme.accent)
      .controlSize(HarnessMonitorControlMetrics.compactControlSize)
      .disabled(isActionInFlight)
      .help("Create board item")
      .accessibilityIdentifier("harness.task-board.new-item")
    }

    if let onEvaluateTaskBoard {
      if store != nil {
        Toggle("Dry run", isOn: $evaluateDryRun)
          .toggleStyle(.checkbox)
          .controlSize(HarnessMonitorControlMetrics.compactControlSize)
          .disabled(isActionInFlight)
          .help("Preview the evaluate without applying any board changes")
          .accessibilityIdentifier("harness.task-board.evaluate.dry-run")
      }
      Button {
        triggerBoardEvaluate(onEvaluateTaskBoard)
      } label: {
        Label(evaluateDryRun ? "Preview" : "Evaluate", systemImage: "checkmark.seal")
          .font(captionSemibold)
      }
      .frame(minHeight: metrics.controlMinHeight)
      .harnessActionButtonStyle(variant: .bordered, tint: HarnessMonitorTheme.accent)
      .controlSize(HarnessMonitorControlMetrics.compactControlSize)
      .disabled(isActionInFlight)
      .help(evaluateDryRun ? "Preview evaluate results without applying" : "Evaluate board state")
      .accessibilityIdentifier("harness.task-board.evaluate")
    }

    if let onRefreshTaskBoard {
      Button {
        onRefreshTaskBoard()
      } label: {
        Label("Sync", systemImage: "arrow.clockwise")
          .font(captionSemibold)
      }
      .frame(minHeight: metrics.controlMinHeight)
      .harnessActionButtonStyle(variant: .bordered, tint: .secondary)
      .controlSize(HarnessMonitorControlMetrics.compactControlSize)
      .disabled(isActionInFlight)
      .help("Sync task board")
      .accessibilityIdentifier("harness.task-board.refresh")
    }
  }

  var aggregateSummaryRow: some View {
    HStack(spacing: HarnessMonitorTheme.spacingSM) {
      aggregateSummaryContent
    }
    .fixedSize(horizontal: true, vertical: false)
  }

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

  var hasBoardContent: Bool {
    cachedPresentation.hasBoardContent
  }

  var boardSection: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      if hasAggregateSummary || hasHeaderActions {
        boardAccessoryRow
      }
      boardContent
        .frame(maxHeight: fillsAvailableHeight ? .infinity : nil)
    }
    .frame(maxHeight: fillsAvailableHeight ? .infinity : nil)
  }

  @MainActor
  func rebuildPresentation(input: TaskBoardOverviewPresentationInput) async {
    presentationGeneration &+= 1
    let generation = presentationGeneration
    let presentation = await presentationWorker.compute(input: input)
    guard !Task.isCancelled, presentationGeneration == generation else {
      return
    }
    if cachedPresentation != presentation {
      cachedPresentation = presentation
      cardSelection = cardSelection.pruning(
        orderedVisibleIDs: presentation.orderedCardIDs
      )
    }
  }
}
