import Foundation
import HarnessMonitorKit
import SwiftUI

struct TaskBoardItemManagementPanel: View {
  let item: TaskBoardItem?
  let metrics: TaskBoardOverviewMetrics
  let isActionInFlight: Bool
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

  init(
    item: TaskBoardItem?,
    metrics: TaskBoardOverviewMetrics,
    isActionInFlight: Bool,
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
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("harness.task-board.manage-item.\(item?.id ?? "new")")
  }

  private var header: some View {
    HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.spacingSM) {
      Label(
        isCreating ? "Create Board Item" : "Manage Board Item",
        systemImage: "slider.horizontal.3"
      )
      .scaledFont(.subheadline.weight(.semibold))
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
      managementPill(draft.status.title, tint: taskBoardStatusColor(for: draft.status))
      managementPill(draft.priority.title, tint: priorityColor(for: draft.priority))
      managementPill(linkLabel, tint: linkTint)
    }
  }

  private var editorFields: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      nativeField("Title", text: $draft.title)
      HarnessMonitorMultilineTextField<Never>(
        placeholder: "Body",
        text: $draft.body,
        minHeight: metrics.editorBodyMinHeight,
        accessibilityLabel: "Body"
      )
      HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingMD) {
        pickerField("Status", selection: $draft.status, values: TaskBoardStatus.allCases)
        pickerField("Priority", selection: $draft.priority, values: TaskBoardPriority.allCases)
        pickerField("Agent Mode", selection: $draft.agentMode, values: TaskBoardAgentMode.allCases)
      }
      nativeField("Tags", text: $draft.tagsText)
      nativeField("Project", text: $draft.projectId)
      HarnessMonitorMultilineTextField<Never>(
        placeholder: "Planning summary",
        text: $draft.planningSummary,
        minHeight: metrics.editorPlanningMinHeight,
        accessibilityLabel: "Planning summary"
      )
      HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingMD) {
        nativeField("Approver", text: $draft.approvedBy)
        nativeField("Approved At", text: $draft.approvedAt)
      }
      HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingMD) {
        nativeField("Linked Session", text: $draft.sessionId)
        nativeField("Work Item", text: $draft.workItemId)
      }
    }
  }

  private var approvalReadout: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      Text("Approval")
        .scaledFont(.caption.weight(.semibold))
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      Text(approvalSummary)
        .scaledFont(.caption)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .textSelection(.enabled)
    }
  }

  private var externalRefsEditor: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      HStack {
        Text("External Refs")
          .scaledFont(.caption.weight(.semibold))
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        Spacer()
        Button {
          draft.externalRefs.append(TaskBoardExternalRefDraft())
        } label: {
          Label("Add Ref", systemImage: "plus")
            .scaledFont(.caption.weight(.semibold))
        }
        .controlSize(HarnessMonitorControlMetrics.compactControlSize)
        .disabled(isActionInFlight)
      }
      ForEach($draft.externalRefs) { $ref in
        HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingSM) {
          Picker("Provider", selection: $ref.provider) {
            ForEach(TaskBoardExternalRefProvider.taskBoardCases, id: \.self) { provider in
              Text(provider.title).tag(provider)
            }
          }
          .labelsHidden()
          .harnessNativeFormControl()
          nativeField("External ID", text: $ref.externalId)
          nativeField("URL", text: $ref.url)
          Button(role: .destructive) {
            draft.externalRefs.removeAll { $0.id == ref.id }
          } label: {
            Image(systemName: "trash")
              .accessibilityHidden(true)
          }
          .buttonStyle(.borderless)
          .frame(minWidth: metrics.iconControlMinWidth, minHeight: metrics.controlMinHeight)
          .help("Remove external ref")
          .accessibilityLabel("Remove external ref")
        }
      }
    }
  }

  private var actionButtons: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: HarnessMonitorTheme.spacingSM) { actionButtonContent }
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) { actionButtonContent }
    }
  }

  @ViewBuilder private var actionButtonContent: some View {
    Button {
      submitDraft()
    } label: {
      Label(
        isCreating ? "Create Item" : "Save Item",
        systemImage: isCreating ? "plus.circle" : "checkmark.circle"
      )
      .scaledFont(.caption.weight(.semibold))
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
          .scaledFont(.caption.weight(.semibold))
      }
      .frame(minHeight: metrics.controlMinHeight)
      .harnessActionButtonStyle(variant: .bordered, tint: HarnessMonitorTheme.accent)
      .controlSize(HarnessMonitorControlMetrics.compactControlSize)
      .disabled(isActionInFlight || onRunOnce == nil)

      Button {
        onEvaluate?(item)
      } label: {
        Label("Evaluate Item", systemImage: "checkmark.seal")
          .scaledFont(.caption.weight(.semibold))
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
          .scaledFont(.caption.weight(.semibold))
      }
      .frame(minHeight: metrics.controlMinHeight)
      .controlSize(HarnessMonitorControlMetrics.compactControlSize)
      .disabled(isActionInFlight || onDelete == nil)
    }

    Button {
      onRefresh?()
    } label: {
      Label("Refresh", systemImage: "arrow.clockwise")
        .scaledFont(.caption.weight(.semibold))
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

  private var externalDestinations: [TaskBoardExternalDestination] {
    var destinations = draft.materializedExternalRefs.compactMap(externalDestination)
    if let prUrl = item?.workflow?.prUrl, let url = URL(string: prUrl) {
      destinations.append(TaskBoardExternalDestination(label: "Pull Request", url: url))
    }
    return destinations
  }

  private func externalDestination(for ref: TaskBoardExternalRef) -> TaskBoardExternalDestination? {
    guard let rawURL = ref.url, let url = URL(string: rawURL) else {
      return nil
    }
    return TaskBoardExternalDestination(label: externalLabel(for: ref), url: url)
  }

  private func submitDraft() {
    if let item {
      onUpdate?(item.id, draft.updateRequest)
    } else {
      onCreate?(draft.createRequest, draft.status)
    }
  }

  private func externalLabel(for ref: TaskBoardExternalRef) -> String {
    "\(ref.provider.title) \(ref.externalId)"
  }

  private func nativeField(_ label: String, text: Binding<String>) -> some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      Text(label)
        .scaledFont(.caption.weight(.semibold))
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      TextField(label, text: text)
        .harnessNativeTextField()
    }
  }

  private func pickerField<Value: CaseIterable & Hashable & Identifiable & TitledTaskBoardValue>(
    _ label: String,
    selection: Binding<Value>,
    values: Value.AllCases
  ) -> some View where Value.AllCases: RandomAccessCollection {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      Text(label)
        .scaledFont(.caption.weight(.semibold))
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      Picker(label, selection: selection) {
        ForEach(values) { value in
          Text(value.title).tag(value)
        }
      }
      .labelsHidden()
      .harnessNativeFormControl()
    }
  }

  private func managementPill(_ label: String, tint: Color) -> some View {
    Text(label)
      .scaledFont(.caption2.weight(.bold))
      .foregroundStyle(tint)
      .lineLimit(1)
      .padding(.horizontal, HarnessMonitorTheme.spacingSM)
      .padding(.vertical, metrics.managementPillVerticalPadding)
      .background(tint.opacity(0.12), in: .capsule)
  }
}
