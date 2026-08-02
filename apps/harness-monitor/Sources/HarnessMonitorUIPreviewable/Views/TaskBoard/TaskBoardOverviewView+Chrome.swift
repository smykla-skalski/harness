import HarnessMonitorKit
import SwiftUI

extension TaskBoardOverviewView {
  @ViewBuilder var boardChrome: some View {
    if hasRouteContent || store != nil {
      if taskBoardSessionID == nil, let orchestratorStatus {
        taskBoardDetailRow {
          TaskBoardOrchestratorSummaryView(
            status: orchestratorStatus,
            taskBoardItems: currentPresentation.taskBoardItems,
            localHostProjectTypes: localHostRoutingStateValue.projectTypes,
            latestEvaluation: evaluationSummary,
            latestEvaluationBaselineRunID: store?.contentUI.dashboard
              .taskBoardEvaluationBaselineRunID,
            isActionInFlight: isActionInFlight,
            actions: actions,
            pendingLiveOperation: pendingLiveOperationBinding
          )
        }
      } else if let evaluationSummary {
        taskBoardDetailRow { evaluationSummaryRow(evaluationSummary) }
      }
    }
    if let orchestratorStatus,
      TaskBoardOrchestratorPresentation.showsManualSteps(
        for: orchestratorStatus,
        scopeSessionID: taskBoardSessionID,
        hasStore: store != nil
      ),
      let store
    {
      taskBoardDetailRow {
        TaskBoardStepRailView(
          store: store,
          status: orchestratorStatus,
          latestEvaluation: evaluationSummary,
          workspace: store.contentUI.dashboard.policyCanvasWorkspace,
          targetItem: currentPresentation.stepRailTargetItem,
          taskBoardItems: taskBoardItems,
          isActionInFlight: isActionInFlight,
          actions: actions,
          flowDefaults: .standard
        )
      }
    }
    if let evaluatePreviewSummaryValue {
      taskBoardDetailRow { evaluatePreviewRow(evaluatePreviewSummaryValue) }
    }
    taskBoardDetailRow { headerTitle }
    if taskBoardSessionID == nil, showsOperationsPanel, let store {
      taskBoardDetailRow {
        TaskBoardOperationsPanel(store: store, taskBoardItems: currentPresentation.taskBoardItems)
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
      // Only pushes apart when both sides carry something. An unconditional
      // spacer strands the controls at the trailing edge of a row whose
      // leading half is empty.
      if hasAggregateSummary && (showsNarrowingControls || hasHeaderActions) {
        Spacer(minLength: HarnessMonitorTheme.spacingMD)
      }
      if showsNarrowingControls {
        TaskBoardSearchField(
          text: boardSearchTextBinding,
          candidates: currentPresentation.searchCandidates
        )
        TaskBoardFilterControls(
          filters: boardFiltersBinding,
          inventory: currentPresentation.filterInventory
        )
        .fixedSize(horizontal: true, vertical: false)
      }
      if hasHeaderActions {
        headerActions
      }
    }
  }

  /// Offered once the board holds something worth narrowing, and kept on while
  /// a filter or a search is active even after it has hidden everything.
  var showsNarrowingControls: Bool {
    taskBoardSessionID == nil
      && (currentPresentation.hasUnfilteredContent
        || !boardFilters.isEmpty
        || !boardSearchFieldText.isEmpty)
  }

  var activeFilterChips: [TaskBoardActiveFilterChip] {
    currentPresentation.filterInventory.activeChips(for: boardFilters)
  }

  var hasHeaderActions: Bool {
    actions.canCreateItem || actions.canEvaluateBoard || actions.canRefreshBoard
  }

  @ViewBuilder var headerActionButtons: some View {
    if actions.canCreateItem {
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

    if actions.canEvaluateBoard {
      Button {
        triggerBoardEvaluate()
      } label: {
        Label(
          evaluateDryRun ? "Preview Evaluate" : "Evaluate Live",
          systemImage: "checkmark.seal"
        )
        .font(captionSemibold)
      }
      .frame(minHeight: metrics.controlMinHeight)
      .harnessActionButtonStyle(variant: .bordered, tint: HarnessMonitorTheme.accent)
      .controlSize(HarnessMonitorControlMetrics.compactControlSize)
      .disabled(isActionInFlight)
      .help(
        evaluateDryRun
          ? "Preview evaluate results without applying changes"
          : "Evaluate and apply live board transitions after confirmation"
      )
      .accessibilityIdentifier("harness.task-board.evaluate")
    }

    if actions.canRefreshBoard {
      Button {
        if taskBoardSyncPhase == .syncing {
          actions.cancelTaskBoardSync()
        } else if taskBoardSyncPhase == .idle {
          actions.refreshTaskBoard()
        }
      } label: {
        switch taskBoardSyncPhase {
        case .idle:
          Label("Sync", systemImage: "arrow.clockwise")
        case .syncing:
          Label("Stop Refresh", systemImage: "stop.circle.fill")
        case .stopping:
          Label("Stopping…", systemImage: "hourglass")
        }
      }
      .font(captionSemibold)
      .frame(minHeight: metrics.controlMinHeight)
      .harnessActionButtonStyle(
        variant: .bordered,
        tint: taskBoardSyncPhase == .syncing ? .red : .secondary
      )
      .controlSize(HarnessMonitorControlMetrics.compactControlSize)
      .disabled(
        taskBoardSyncPhase == .stopping
          || (taskBoardSyncPhase == .idle && isActionInFlight)
      )
      .help(taskBoardSyncHelp)
      .accessibilityIdentifier("harness.task-board.refresh")
    }
  }

  private var taskBoardSyncPhase: TaskBoardSyncPhase {
    store?.contentUI.dashboard.taskBoardSyncPhase ?? .idle
  }

  private var taskBoardSyncHelp: String {
    switch taskBoardSyncPhase {
    case .idle:
      "Pull external sources and apply changes to the task board"
    case .syncing:
      "Stop the active task source refresh"
    case .stopping:
      "Waiting for the active task source refresh to stop"
    }
  }

  var aggregateSummaryRow: some View {
    HStack(spacing: HarnessMonitorTheme.spacingSM) {
      aggregateSummaryContent
    }
    .fixedSize(horizontal: true, vertical: false)
  }

  var hasBoardContent: Bool {
    currentPresentation.hasBoardContent
  }

  var boardSection: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      if hasAggregateSummary || hasHeaderActions || showsNarrowingControls {
        // The search suggestions hang out of this row over what follows it, and
        // a later sibling in a stack draws on top by default.
        boardAccessoryRow
          .zIndex(1)
      }
      let chips = activeFilterChips
      if !chips.isEmpty {
        TaskBoardActiveFilterChips(filters: boardFiltersBinding, chips: chips)
      }
      boardContent
        .frame(maxHeight: fillsAvailableHeight ? .infinity : nil)
    }
    .frame(maxHeight: fillsAvailableHeight ? .infinity : nil)
  }
}
