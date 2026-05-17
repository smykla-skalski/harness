import Foundation
import HarnessMonitorKit
import SwiftUI

struct TaskBoardItemManagementPanel: View {
  let item: TaskBoardItem?
  let metrics: TaskBoardOverviewMetrics
  let isActionInFlight: Bool
  let store: HarnessMonitorStore?
  let onCreate: ((TaskBoardCreateItemRequest, TaskBoardStatus) -> Void)?
  let onUpdate: ((String, TaskBoardUpdateItemRequest) -> Void)?
  let onDelete: ((TaskBoardItem) -> Void)?
  let onRunOnce: ((TaskBoardItem) -> Void)?
  let onEvaluate: ((TaskBoardItem) -> Void)?
  let onBeginPlan: ((TaskBoardItem) -> Void)?
  let onSubmitPlan: ((TaskBoardItem, String) -> Void)?
  let onApprovePlan: ((TaskBoardItem, String, String?) -> Void)?
  let onRefresh: (() -> Void)?
  let onClose: () -> Void

  @State private var draft: TaskBoardItemEditorDraft
  @State private var projectTypeSuggestions: [String] = []
  @Environment(\.fontScale)
  private var fontScale

  private var subheadlineSemibold: Font {
    HarnessMonitorTextSize.scaledFont(.subheadline.weight(.semibold), by: fontScale)
  }
  private var captionFont: Font {
    HarnessMonitorTextSize.scaledFont(.caption, by: fontScale)
  }
  private var captionSemibold: Font {
    HarnessMonitorTextSize.scaledFont(.caption.weight(.semibold), by: fontScale)
  }

  init(
    item: TaskBoardItem?,
    metrics: TaskBoardOverviewMetrics,
    isActionInFlight: Bool,
    store: HarnessMonitorStore? = nil,
    onCreate: ((TaskBoardCreateItemRequest, TaskBoardStatus) -> Void)?,
    onUpdate: ((String, TaskBoardUpdateItemRequest) -> Void)?,
    onDelete: ((TaskBoardItem) -> Void)?,
    onRunOnce: ((TaskBoardItem) -> Void)?,
    onEvaluate: ((TaskBoardItem) -> Void)?,
    onBeginPlan: ((TaskBoardItem) -> Void)?,
    onSubmitPlan: ((TaskBoardItem, String) -> Void)?,
    onApprovePlan: ((TaskBoardItem, String, String?) -> Void)?,
    onRefresh: (() -> Void)?,
    onClose: @escaping () -> Void
  ) {
    self.item = item
    self.metrics = metrics
    self.isActionInFlight = isActionInFlight
    self.store = store
    self.onCreate = onCreate
    self.onUpdate = onUpdate
    self.onDelete = onDelete
    self.onRunOnce = onRunOnce
    self.onEvaluate = onEvaluate
    self.onBeginPlan = onBeginPlan
    self.onSubmitPlan = onSubmitPlan
    self.onApprovePlan = onApprovePlan
    self.onRefresh = onRefresh
    self.onClose = onClose
    _draft = State(
      initialValue: item.map(TaskBoardItemEditorDraft.init) ?? TaskBoardItemEditorDraft()
    )
  }

  var body: some View {
    VStack(alignment: .leading, spacing: metrics.managementPanelSpacing) {
      header
      statusPills
      TaskBoardManagementFacts(facts: managementFacts)
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
    .background(
      .background.opacity(0.56),
      in: .rect(cornerRadius: metrics.managementPanelCornerRadius)
    )
    .overlay(
      RoundedRectangle(cornerRadius: metrics.managementPanelCornerRadius)
        .stroke(HarnessMonitorTheme.controlBorder.opacity(0.62), lineWidth: 1)
    )
    .task { await loadProjectTypeSuggestions() }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("harness.task-board.manage-item.\(item?.id ?? "new")")
    .onChange(of: item) { _, newValue in
      draft = newValue.map(TaskBoardItemEditorDraft.init) ?? TaskBoardItemEditorDraft()
    }
  }

  @MainActor
  private func loadProjectTypeSuggestions() async {
    projectTypeSuggestions = await TaskBoardHostProjectTypeSuggestions.load(from: store)
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

  private var header: some View {
    HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.spacingSM) {
      Label(
        isCreating ? "Create Board Item" : "Manage Board Item",
        systemImage: "slider.horizontal.3"
      )
      .font(subheadlineSemibold)
      Spacer(minLength: HarnessMonitorTheme.spacingSM)
      Button(action: onClose) {
        Image(systemName: "xmark")
          .accessibilityHidden(true)
      }
      .buttonStyle(.borderless)
      .frame(minWidth: metrics.iconControlMinWidth, minHeight: metrics.controlMinHeight)
      .help("Close board item")
      .accessibilityLabel("Close item panel")
    }
  }

  private var statusPills: some View {
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

  private var editorFields: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      TaskBoardManagementNativeField(label: "Title", text: $draft.title)
      HarnessMonitorMultilineTextField<Never>(
        placeholder: "Body",
        text: $draft.body,
        minHeight: metrics.editorBodyMinHeight,
        accessibilityLabel: "Body"
      )
      HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingMD) {
        TaskBoardManagementPickerField(
          label: "Status",
          selection: $draft.status,
          values: TaskBoardStatus.allCases
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
      HarnessMonitorMultilineTextField<Never>(
        placeholder: "Planning summary",
        text: $draft.planningSummary,
        minHeight: metrics.editorPlanningMinHeight,
        accessibilityLabel: "Planning summary"
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

  private var approvalReadout: some View {
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

  private var actionButtons: some View {
    HStack(spacing: HarnessMonitorTheme.spacingSM) {
      actionButtonContent
    }
    .fixedSize(horizontal: true, vertical: false)
  }

  @ViewBuilder private var actionButtonContent: some View {
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

    if let item {
      TaskBoardPlanLifecycleActionButtons(
        item: item,
        draft: draft,
        metrics: metrics,
        isActionInFlight: isActionInFlight,
        onBeginPlan: onBeginPlan,
        onSubmitPlan: onSubmitPlan,
        onApprovePlan: onApprovePlan
      )

      Button {
        onRunOnce?(item)
      } label: {
        Label("Run Once", systemImage: "play.circle")
          .font(captionSemibold)
      }
      .frame(minHeight: metrics.controlMinHeight)
      .harnessActionButtonStyle(variant: .bordered, tint: HarnessMonitorTheme.accent)
      .controlSize(HarnessMonitorControlMetrics.compactControlSize)
      .disabled(isActionInFlight || onRunOnce == nil)

      Button {
        onEvaluate?(item)
      } label: {
        Label("Evaluate Item", systemImage: "checkmark.seal")
          .font(captionSemibold)
      }
      .frame(minHeight: metrics.controlMinHeight)
      .harnessActionButtonStyle(variant: .bordered, tint: HarnessMonitorTheme.accent)
      .controlSize(HarnessMonitorControlMetrics.compactControlSize)
      .disabled(isActionInFlight || onEvaluate == nil)
      .help("Evaluate this board item")

      Button(role: .destructive) {
        onDelete?(item)
        onClose()
      } label: {
        Label("Delete", systemImage: "trash")
          .font(captionSemibold)
      }
      .frame(minHeight: metrics.controlMinHeight)
      .controlSize(HarnessMonitorControlMetrics.compactControlSize)
      .disabled(isActionInFlight || onDelete == nil)
    }

    Button {
      onRefresh?()
    } label: {
      Label("Refresh", systemImage: "arrow.clockwise")
        .font(captionSemibold)
    }
    .frame(minHeight: metrics.controlMinHeight)
    .harnessActionButtonStyle(variant: .bordered, tint: .secondary)
    .controlSize(HarnessMonitorControlMetrics.compactControlSize)
    .disabled(isActionInFlight || onRefresh == nil)
    .help("Refresh task board")
    .accessibilityIdentifier("harness.task-board.manage-item.refresh")
  }

  private var isCreating: Bool {
    item == nil
  }

  private var canSubmit: Bool {
    isCreating ? onCreate != nil : onUpdate != nil
  }

  private var linkLabel: String {
    draft.sessionId.isEmpty || draft.workItemId.isEmpty ? "Board Only" : "Session Task"
  }

  private var linkTint: Color {
    linkLabel == "Session Task" ? HarnessMonitorTheme.accent : HarnessMonitorTheme.caution
  }

  private var approvalSummary: String {
    if !draft.approvedBy.isEmpty && !draft.approvedAt.isEmpty {
      return "Approved by \(draft.approvedBy) at \(draft.approvedAt)"
    }
    if !draft.approvedBy.isEmpty {
      return "Approved by \(draft.approvedBy)"
    }
    return "Not approved"
  }

  private var managementFacts: [TaskBoardManagementFact] {
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

  private func submitDraft() {
    if let item {
      onUpdate?(item.id, draft.updateRequest)
    } else {
      onCreate?(draft.createRequest, draft.status)
    }
  }
}
