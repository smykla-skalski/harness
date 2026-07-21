import Foundation
import HarnessMonitorKit
import SwiftUI

@MainActor
@Observable
final class TaskBoardItemCreationOutcome {
  var succeeded = false
}

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
  @Environment(\.fontScale)
  var fontScale
  @Environment(\.dismiss)
  private var dismiss

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
    _draft = State(
      initialValue: item.map(TaskBoardItemEditorDraft.init) ?? TaskBoardItemEditorDraft()
    )
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
        selectionModel: selectionModel,
        actions: actions
      )
      editorFields
      routesToEditor
      approvalReadout
      externalRefsEditor
      if !externalDestinations.isEmpty {
        TaskBoardExternalLinks(destinations: externalDestinations, metrics: metrics)
      }
      actionButtons
    }
    .padding(HarnessMonitorTheme.spacingMD)
    .frame(maxWidth: .infinity, minHeight: metrics.managementPanelMinHeight, alignment: .leading)
    .task { await loadProjectTypeSuggestions() }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("harness.task-board.manage-item.\(item?.id ?? "new")")
    .onChange(of: item) { _, newValue in
      draft = newValue.map(TaskBoardItemEditorDraft.init) ?? TaskBoardItemEditorDraft()
    }
    .onChange(of: creationOutcome.succeeded) { _, succeeded in
      if succeeded {
        dismiss()
      }
    }
  }

  @MainActor
  func loadProjectTypeSuggestions() async {
    projectTypeSuggestions = await TaskBoardHostProjectTypeSuggestions.load(from: actions.store)
  }

  var panelCaptionSemibold: Font {
    captionSemibold
  }

  var targetProjectTypesBinding: Binding<[String]> {
    $draft.targetProjectTypes
  }

  var projectTypeSuggestionValues: [String] {
    projectTypeSuggestions
  }

  var visibleExternalRefIDs: [UUID] {
    draft.monitorVisibleExternalRefIDs
  }

  var visibleExternalRefs: [TaskBoardExternalRef] {
    draft.monitorVisibleExternalRefs
  }

  func appendExternalRefDraft() {
    draft.externalRefs.append(TaskBoardExternalRefDraft())
  }

  func removeExternalRefDraft(id: UUID) {
    draft.externalRefs.removeAll { $0.id == id }
  }

  func externalRefBinding(
    for refID: UUID
  ) -> Binding<TaskBoardExternalRefDraft>? {
    guard let index = draft.externalRefs.firstIndex(where: { $0.id == refID }) else {
      return nil
    }
    return $draft.externalRefs[index]
  }

  var header: some View {
    HStack(alignment: .center, spacing: HarnessMonitorTheme.spacingSM) {
      HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.spacingSM) {
        Image(systemName: "slider.horizontal.3")
          .font(headerSymbolFont)
          .accessibilityHidden(true)
        Text(isCreating ? "Create Board Item" : "Manage Board Item")
          .font(headerTitleFont)
      }
      .accessibilityElement(children: .combine)
      .accessibilityAddTraits(.isHeader)
      Spacer(minLength: HarnessMonitorTheme.spacingSM)
      Button {
        dismiss()
      } label: {
        Image(systemName: "xmark.circle.fill")
          .scaledFont(.title3)
          .foregroundStyle(.secondary)
          .frame(
            width: max(metrics.iconControlMinWidth, metrics.controlMinHeight),
            height: max(metrics.iconControlMinWidth, metrics.controlMinHeight)
          )
          .contentShape(.circle)
          .accessibilityHidden(true)
      }
      .harnessDismissButtonStyle()
      .frame(minWidth: metrics.iconControlMinWidth, minHeight: metrics.controlMinHeight)
      .help("Close board item")
      .accessibilityLabel("Close item panel")
      .accessibilityHint("Dismiss the board item sheet")
      .keyboardShortcut(.cancelAction)
    }
  }

  var statusPills: some View {
    HStack(spacing: HarnessMonitorTheme.spacingXS) {
      TaskBoardManagementPill(
        label: draft.status.title,
        tint: taskBoardStatusColor(for: draft.status),
        verticalPadding: metrics.managementPillVerticalPadding
      )
      TaskBoardManagementPill(
        label: draft.priority.title,
        tint: priorityColor(for: draft.priority),
        verticalPadding: metrics.managementPillVerticalPadding
      )
      TaskBoardManagementPill(
        label: linkLabel,
        tint: linkTint,
        verticalPadding: metrics.managementPillVerticalPadding
      )
    }
  }

  var editorFields: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      TaskBoardManagementNativeField(label: "Title", text: $draft.title)
      TaskBoardDescriptionSection(
        text: $draft.body,
        minHeight: metrics.editorBodyMinHeight
      )
      HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingMD) {
        TaskBoardManagementPickerField(
          label: "Status",
          selection: $draft.status,
          values: TaskBoardStatus.currentLaneCases
        )
        TaskBoardManagementPickerField(
          label: "Priority",
          selection: $draft.priority,
          values: TaskBoardPriority.allCases
        )
        TaskBoardManagementPickerField(
          label: "Agent Mode",
          selection: $draft.agentMode,
          values: TaskBoardAgentMode.allCases
        )
      }
      TaskBoardManagementNativeField(label: "Tags", text: $draft.tagsText)
      TaskBoardManagementNativeField(label: "Project", text: $draft.projectId)
      TaskBoardManagementMultilineField(
        label: "Planning summary",
        text: $draft.planningSummary,
        minHeight: metrics.editorPlanningMinHeight,
        accessibilityIdentifier: "harness.task-board.manage-item.planning-summary"
      )
      HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingMD) {
        TaskBoardManagementNativeField(label: "Approver", text: $draft.approvedBy)
        TaskBoardManagementNativeField(label: "Approved At", text: $draft.approvedAt)
      }
      HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingMD) {
        TaskBoardManagementNativeField(label: "Linked Session", text: $draft.sessionId)
        TaskBoardManagementNativeField(label: "Work Item", text: $draft.workItemId)
      }
    }
  }

  var approvalReadout: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      Text("Approval")
        .font(captionSemibold)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      Text(approvalSummary)
        .font(captionFont)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .textSelection(.enabled)
    }
  }

  var actionButtons: some View {
    HStack(spacing: HarnessMonitorTheme.spacingSM) {
      actionButtonContent
    }
    .fixedSize(horizontal: true, vertical: false)
  }

  @ViewBuilder var actionButtonContent: some View {
    Button {
      submitDraft()
    } label: {
      Label(
        isCreating ? "Create Item" : "Save Item",
        systemImage: isCreating ? "plus.circle" : "checkmark.circle"
      )
      .font(captionSemibold)
    }
    .frame(minHeight: metrics.controlMinHeight)
    .harnessActionButtonStyle(variant: .bordered, tint: HarnessMonitorTheme.accent)
    .controlSize(HarnessMonitorControlMetrics.compactControlSize)
    .disabled(isActionInFlight || !draft.canSubmit || !canSubmit)
    .accessibilityIdentifier("harness.task-board.manage-item.submit")

    if let item {
      TaskBoardPlanLifecycleActionButtons(
        item: item,
        draft: draft,
        metrics: metrics,
        isActionInFlight: isActionInFlight,
        actions: actions
      )

      TaskBoardItemLiveActionButtons(
        item: item,
        metrics: metrics,
        captionFont: captionSemibold,
        isActionInFlight: isActionInFlight,
        runOnceDryRun: runOnceDryRun,
        evaluateDryRun: evaluateDryRun,
        actions: actions,
        evaluatePreviewState: evaluatePreviewState
      )

      Button(role: .destructive) {
        actions.deleteTaskBoardItem(item)
        dismiss()
      } label: {
        Label("Delete", systemImage: "trash")
          .font(captionSemibold)
      }
      .frame(minHeight: metrics.controlMinHeight)
      .controlSize(HarnessMonitorControlMetrics.compactControlSize)
      .disabled(isActionInFlight || !actions.canDeleteItem)
    }

    TaskBoardItemSyncActionButton(
      metrics: metrics,
      captionFont: captionSemibold,
      isActionInFlight: isActionInFlight,
      actions: actions
    )
  }

  var isCreating: Bool {
    item == nil
  }

  var canSubmit: Bool {
    isCreating ? actions.canCreateItem : actions.canUpdateItem
  }

  var linkLabel: String {
    draft.sessionId.isEmpty || draft.workItemId.isEmpty ? "Board Only" : "Session Task"
  }

  var linkTint: Color {
    linkLabel == "Session Task" ? HarnessMonitorTheme.accent : HarnessMonitorTheme.caution
  }

  var approvalSummary: String {
    if !draft.approvedBy.isEmpty && !draft.approvedAt.isEmpty {
      return "Approved by \(draft.approvedBy) at \(draft.approvedAt)"
    }
    if !draft.approvedBy.isEmpty {
      return "Approved by \(draft.approvedBy)"
    }
    return "Not approved"
  }

  var managementFacts: [TaskBoardManagementFact] {
    guard let item else {
      return [TaskBoardManagementFact("Mode", value: draft.agentMode.title)]
    }
    var facts = [
      TaskBoardManagementFact("ID", value: item.id),
      TaskBoardManagementFact("Mode", value: item.agentMode.title),
    ]
    if let worktree = item.workflow?.worktree {
      facts.append(TaskBoardManagementFact("Worktree", value: worktree))
    }
    if let branch = item.workflow?.branch {
      facts.append(TaskBoardManagementFact("Branch", value: branch))
    }
    if let workflow = item.workflow {
      facts.append(TaskBoardManagementFact("Workflow", value: workflow.status.title))
    }
    return facts
  }

  func submitDraft() {
    if let item {
      actions.updateTaskBoardItem(item.id, request: draft.updateRequest)
    } else {
      actions.createTaskBoardItem(
        draft.createRequest,
        initialStatus: draft.status,
        outcome: creationOutcome
      )
    }
  }
}
