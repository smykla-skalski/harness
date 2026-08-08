import Foundation
import HarnessMonitorKit
import SwiftUI

struct TaskBoardItemManagementPanel: View {
  let item: TaskBoardItem?
  let metrics: TaskBoardOverviewMetrics
  let isActionInFlight: Bool
  let runOnceDryRun: Bool
  let evaluateDryRun: Bool
  let actions: TaskBoardOverviewActions
  let evaluatePreviewState: TaskBoardEvaluatePreviewState
  let selectionModel: TaskBoardCardSelectionModel
  let backlink: TaskBoardParentBacklink
  let childrenSummary: TaskBoardUmbrellaChildrenSummary?

  @State private var draft: TaskBoardItemEditorDraft
  @State private var projectTypeSuggestions: [String] = []
  @State private var creationOutcome = TaskBoardItemCreationOutcome()
  @State private var triageInspector = TaskBoardTriageInspectorState()
  @State private var reviewReportState = TaskBoardReviewReportState()
  @State private var workflowProgressState = TaskBoardWorkflowProgressState()
  @State private var workerProgressState = TaskBoardWorkerProgressState()
  @Environment(\.fontScale)
  var fontScale
  @Environment(\.dismiss)
  var dismiss

  private var triageInspectorLoadKey: TaskBoardTriageInspectorLoadKey? {
    item.map {
      TaskBoardTriageInspectorLoadKey(itemID: $0.id, updatedAt: $0.updatedAt)
    }
  }

  private var reviewReportLoadKey: TaskBoardReviewReportLoadKey? {
    guard let item, item.showsReviewReport else { return nil }
    return TaskBoardReviewReportLoadKey(
      itemID: item.id,
      updatedAt: item.updatedAt,
      taskBoardRevision: actions.store?.contentUI.dashboard.taskBoardRevision ?? 0
    )
  }

  private var workflowProgressLoadKey: TaskBoardWorkflowProgressLoadKey? {
    guard let item, item.showsWorkflowProgress else { return nil }
    return TaskBoardWorkflowProgressLoadKey(
      itemID: item.id,
      executionID: item.workflow?.executionId,
      updatedAt: item.updatedAt
    )
  }

  private var workerProgressLoadKey: TaskBoardWorkerProgressLoadKey? {
    guard let item, let workItemID = item.workItemId, item.showsWorkerProgress else { return nil }
    return TaskBoardWorkerProgressLoadKey(
      itemID: item.id,
      workItemID: workItemID,
      updatedAt: item.updatedAt
    )
  }

  var headerTitleFont: Font {
    HarnessMonitorTextSize.scaledFont(.title2.weight(.semibold), by: fontScale)
  }
  var headerSymbolFont: Font {
    HarnessMonitorTextSize.scaledFont(.title3.weight(.semibold), by: fontScale)
  }
  var captionFont: Font {
    HarnessMonitorTextSize.scaledFont(.caption, by: fontScale)
  }
  var captionSemibold: Font {
    HarnessMonitorTextSize.scaledFont(.caption.weight(.semibold), by: fontScale)
  }

  var draftValue: TaskBoardItemEditorDraft {
    get { draft }
    nonmutating set { draft = newValue }
  }

  var draftBinding: Binding<TaskBoardItemEditorDraft> {
    Binding(get: { draftValue }, set: { draftValue = $0 })
  }

  var projectTypeSuggestionsValue: [String] {
    get { projectTypeSuggestions }
    nonmutating set { projectTypeSuggestions = newValue }
  }

  var creationOutcomeValue: TaskBoardItemCreationOutcome { creationOutcome }

  init(
    item: TaskBoardItem?,
    metrics: TaskBoardOverviewMetrics,
    isActionInFlight: Bool,
    runOnceDryRun: Bool = true,
    evaluateDryRun: Bool = true,
    actions: TaskBoardOverviewActions,
    evaluatePreviewState: TaskBoardEvaluatePreviewState,
    selectionModel: TaskBoardCardSelectionModel,
    backlink: TaskBoardParentBacklink = .none,
    childrenSummary: TaskBoardUmbrellaChildrenSummary? = nil
  ) {
    self.item = item
    self.metrics = metrics
    self.isActionInFlight = isActionInFlight
    self.runOnceDryRun = runOnceDryRun
    self.evaluateDryRun = evaluateDryRun
    self.actions = actions
    self.evaluatePreviewState = evaluatePreviewState
    self.selectionModel = selectionModel
    self.backlink = backlink
    self.childrenSummary = childrenSummary
    _draft = State(initialValue: Self.sanitizedDraft(for: item))
  }

  private static func sanitizedDraft(for item: TaskBoardItem?) -> TaskBoardItemEditorDraft {
    var draft = item.map(TaskBoardItemEditorDraft.init) ?? TaskBoardItemEditorDraft()
    draft.approvedAt = TaskBoardApprovedAtPickerValue.sanitizedApprovedAt(draft.approvedAt)
    return draft
  }

  var body: some View {
    VStack(alignment: .leading, spacing: metrics.managementPanelSpacing) {
      header
      statusPills
      TaskBoardManagementFacts(facts: managementFacts)
      TaskBoardManagementHierarchySection(
        backlink: backlink,
        childrenSummary: childrenSummary,
        metrics: metrics,
        selectionModel: selectionModel
      )
      editorFields
      routesToEditor
      approvalReadout
      if let item {
        if workflowProgressLoadKey != nil {
          TaskBoardItemWorkflowProgressSection(
            item: item,
            actions: actions,
            state: workflowProgressState
          )
        }
        if workerProgressLoadKey != nil {
          TaskBoardItemWorkerProgressSection(
            item: item,
            actions: actions,
            state: workerProgressState
          )
        }
        if item.showsReviewReport {
          TaskBoardItemReviewReportSection(
            item: item,
            actions: actions,
            state: reviewReportState
          )
        }
        TaskBoardManagementTriageSection(
          item: item,
          metrics: metrics,
          isActionInFlight: isActionInFlight,
          actions: actions,
          inspector: triageInspector
        )
      }
      externalRefsEditor
      if !externalDestinations.isEmpty {
        TaskBoardExternalLinks(destinations: externalDestinations, metrics: metrics)
      }
      actionButtons
    }
    .padding(HarnessMonitorTheme.spacingMD)
    .frame(maxWidth: .infinity, minHeight: metrics.managementPanelMinHeight, alignment: .leading)
    .task { await loadProjectTypeSuggestions() }
    .task(id: triageInspectorLoadKey) {
      guard let item else { return }
      await triageInspector.load(item: item, actions: actions)
    }
    .task(id: reviewReportLoadKey) {
      guard let item, item.showsReviewReport else { return }
      await reviewReportState.load(item: item, actions: actions)
    }
    .task(id: workflowProgressLoadKey) {
      guard let item, workflowProgressLoadKey != nil else { return }
      await workflowProgressState.load(item: item, actions: actions)
    }
    .task(id: workerProgressLoadKey) {
      guard let item, workerProgressLoadKey != nil else { return }
      await workerProgressState.load(item: item, actions: actions)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("harness.task-board.manage-item.\(item?.id ?? "new")")
    .onChange(of: item) { _, newValue in
      draft = Self.sanitizedDraft(for: newValue)
    }
    .onChange(of: creationOutcome.succeeded) { _, succeeded in
      if succeeded {
        dismiss()
      }
    }
  }

}
