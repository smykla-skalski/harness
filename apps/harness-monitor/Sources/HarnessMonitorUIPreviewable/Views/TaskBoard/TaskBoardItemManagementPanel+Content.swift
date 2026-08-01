import HarnessMonitorKit
import SwiftUI

extension TaskBoardItemManagementPanel {
  @MainActor
  func loadProjectTypeSuggestions() async {
    projectTypeSuggestionsValue = await TaskBoardHostProjectTypeSuggestions.load(
      from: actions.store)
  }

  var panelCaptionSemibold: Font {
    captionSemibold
  }

  var targetProjectTypesBinding: Binding<[String]> {
    draftBinding.targetProjectTypes
  }

  var approvedAtBinding: Binding<Date> {
    Binding(
      get: {
        TaskBoardApprovedAtPickerValue.date(fromApprovedAt: draftValue.approvedAt, fallback: Date())
      },
      set: { draftValue.approvedAt = TaskBoardApprovedAtPickerValue.approvedAtString(from: $0) }
    )
  }

  var projectTypeSuggestionValues: [String] {
    projectTypeSuggestionsValue
  }

  var visibleExternalRefIDs: [UUID] {
    draftValue.externalRefs.map(\.id)
  }

  var visibleExternalRefs: [TaskBoardExternalRef] {
    draftValue.materializedExternalRefs
  }

  func appendExternalRefDraft() {
    draftValue.externalRefs.append(TaskBoardExternalRefDraft())
  }

  func removeExternalRefDraft(id: UUID) {
    draftValue.externalRefs.removeAll { $0.id == id }
  }

  func externalRefBinding(
    for refID: UUID
  ) -> Binding<TaskBoardExternalRefDraft>? {
    guard let index = draftValue.externalRefs.firstIndex(where: { $0.id == refID }) else {
      return nil
    }
    return draftBinding.externalRefs[index]
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
        label: draftValue.status.title,
        tint: taskBoardStatusColor(for: draftValue.status),
        verticalPadding: metrics.managementPillVerticalPadding
      )
      TaskBoardManagementPill(
        label: draftValue.priority.title,
        tint: priorityColor(for: draftValue.priority),
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
      TaskBoardManagementNativeField(label: "Title", text: draftBinding.title)
      TaskBoardDescriptionSection(
        text: draftBinding.body,
        minHeight: metrics.editorBodyMinHeight
      )
      HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingMD) {
        TaskBoardManagementPickerField(
          label: "Status",
          selection: draftBinding.status,
          values: TaskBoardStatus.currentLaneCases
        )
        TaskBoardManagementPickerField(
          label: "Priority",
          selection: draftBinding.priority,
          values: TaskBoardPriority.allCases
        )
        TaskBoardManagementPickerField(
          label: "Agent Mode",
          selection: draftBinding.agentMode,
          values: TaskBoardAgentMode.allCases
        )
      }
      TaskBoardManagementNativeField(label: "Tags", text: draftBinding.tagsText)
      TaskBoardManagementNativeField(label: "Project", text: draftBinding.projectId)
      TaskBoardManagementMultilineField(
        label: "Planning summary",
        text: draftBinding.planningSummary,
        minHeight: metrics.editorPlanningMinHeight,
        accessibilityIdentifier: "harness.task-board.manage-item.planning-summary"
      )
      HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingMD) {
        TaskBoardManagementNativeField(label: "Approver", text: draftBinding.approvedBy)
        TaskBoardManagementDateField(label: "Approved At", date: approvedAtBinding)
      }
      HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingMD) {
        TaskBoardManagementNativeField(label: "Linked Session", text: draftBinding.sessionId)
        TaskBoardManagementNativeField(label: "Work Item", text: draftBinding.workItemId)
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
    HarnessMonitorWrapLayout(
      spacing: HarnessMonitorTheme.spacingSM,
      lineSpacing: HarnessMonitorTheme.spacingSM
    ) {
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
      .disabled(isActionInFlight || !draftValue.canSubmit || !canSubmit)
      .accessibilityIdentifier("harness.task-board.manage-item.submit")

      if let item {
        TaskBoardPlanLifecycleActionButtons(
          item: item,
          draft: draftValue,
          approvedAt: approvedAtBinding,
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
  }

  var isCreating: Bool {
    item == nil
  }

  var canSubmit: Bool {
    isCreating ? actions.canCreateItem : actions.canUpdateItem
  }

  var linkLabel: String {
    draftValue.sessionId.isEmpty || draftValue.workItemId.isEmpty ? "Board Only" : "Session Task"
  }

  var linkTint: Color {
    linkLabel == "Session Task" ? HarnessMonitorTheme.accent : HarnessMonitorTheme.caution
  }

  var approvalSummary: String {
    if !draftValue.approvedBy.isEmpty && !draftValue.approvedAt.isEmpty {
      return "Approved by \(draftValue.approvedBy) at \(draftValue.approvedAt)"
    }
    if !draftValue.approvedBy.isEmpty {
      return "Approved by \(draftValue.approvedBy)"
    }
    return "Not approved"
  }

  var managementFacts: [TaskBoardManagementFact] {
    guard let item else {
      return [TaskBoardManagementFact("Mode", value: draftValue.agentMode.title)]
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
      actions.updateTaskBoardItem(item.id, request: draftValue.updateRequest)
    } else {
      actions.createTaskBoardItem(draftValue.createRequest, outcome: creationOutcomeValue)
    }
  }
}
