import Foundation
import HarnessMonitorKit
import SwiftUI

protocol TitledTaskBoardValue {
  var title: String { get }
}

extension TaskBoardStatus: TitledTaskBoardValue {}
extension TaskBoardPriority: TitledTaskBoardValue {}
extension TaskBoardAgentMode: TitledTaskBoardValue {}

extension TaskBoardExternalRefProvider {
  static let taskBoardCases: [TaskBoardExternalRefProvider] = [.gitHub]

  var title: String {
    switch self {
    case .gitHub:
      "GitHub"
    case .todoist:
      "Todoist"
    }
  }

  var isVisibleInMonitorUI: Bool {
    switch self {
    case .gitHub:
      true
    case .todoist:
      false
    }
  }
}

struct TaskBoardManagementFact: Identifiable {
  let id: String
  let label: String
  let value: String

  init(_ label: String, value: String) {
    id = label
    self.label = label
    self.value = value
  }
}

struct TaskBoardExternalDestination: Identifiable {
  let label: String
  let url: URL

  var id: URL { url }
}

struct TaskBoardManagementFacts: View {
  let facts: [TaskBoardManagementFact]
  @Environment(\.fontScale)
  private var fontScale

  // Subscribe to `fontScale` once at the view level and precompute fonts
  // for the row pair. The previous shape stamped `.scaledFont(...)` on
  // every `Text` inside the `ForEach`, planting a `ScaledFontModifier`
  // per text node — and that modifier subscribes to `\.fontScale` per
  // node. In the management panel (2 Text per fact × N facts) that's a
  // big `EnvironmentWriter: Font?` cascade. Hoisting brings it to one
  // subscription per `TaskBoardManagementFacts` body.
  private var labelFont: Font {
    HarnessMonitorTextSize.scaledFont(.caption.weight(.semibold), by: fontScale)
  }
  private var valueFont: Font {
    HarnessMonitorTextSize.scaledFont(.caption, by: fontScale)
  }

  var body: some View {
    let labelFont = labelFont
    let valueFont = valueFont
    return Grid(alignment: .leading, horizontalSpacing: HarnessMonitorTheme.spacingMD) {
      ForEach(facts) { fact in
        GridRow {
          Text(fact.label)
            .font(labelFont)
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          Text(fact.value)
            .font(valueFont)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
        }
      }
    }
  }
}

struct TaskBoardExternalLinks: View {
  let destinations: [TaskBoardExternalDestination]
  let metrics: TaskBoardOverviewMetrics
  @Environment(\.fontScale)
  private var fontScale

  private var labelFont: Font {
    HarnessMonitorTextSize.scaledFont(.caption.weight(.semibold), by: fontScale)
  }

  var body: some View {
    let labelFont = labelFont
    return ViewThatFits(in: .horizontal) {
      HStack(spacing: HarnessMonitorTheme.spacingSM) { links(labelFont: labelFont) }
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
        links(labelFont: labelFont)
      }
    }
  }

  @ViewBuilder
  private func links(labelFont: Font) -> some View {
    ForEach(destinations) { destination in
      Link(destination: destination.url) {
        Label(destination.label, systemImage: "arrow.up.right.square")
          .font(labelFont)
      }
      .frame(minHeight: metrics.controlMinHeight)
      .harnessActionButtonStyle(variant: .bordered, tint: HarnessMonitorTheme.accent)
      .controlSize(HarnessMonitorControlMetrics.compactControlSize)
      .help("Open \(destination.label)")
    }
  }
}

struct TaskBoardDescriptionSection: View {
  @Binding var text: String
  let minHeight: CGFloat

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      Text("Description")
        .scaledFont(.caption.weight(.semibold))
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      content
    }
  }

  @ViewBuilder private var content: some View {
    TaskBoardMarkdownDescriptionContent(text: $text, minHeight: minHeight)
  }
}

private struct TaskBoardDescriptionEditor: View {
  @Binding var text: String
  let minHeight: CGFloat

  var body: some View {
    HarnessMonitorInlineMultilineTextField(
      title: "Description",
      text: $text,
      prompt: "Description",
      hasVisibleLabel: true,
      accessibilityIdentifier: "harness.task-board.manage-item.body",
      minHeight: minHeight,
      maxHeight: minHeight
    )
  }
}

private enum TaskBoardDescriptionPreviewMode: String, CaseIterable, Identifiable {
  case markdown
  case rendered

  var id: Self { self }

  var title: String {
    switch self {
    case .markdown:
      "Markdown"
    case .rendered:
      "Rendered"
    }
  }

  var accessibilityID: String {
    "harness.task-board.manage-item.body.mode.\(rawValue)"
  }

  var rendering: HarnessMonitorMarkdownTextRendering {
    switch self {
    case .markdown:
      .plainPreview
    case .rendered:
      .rich
    }
  }
}

private struct TaskBoardMarkdownDescriptionContent: View {
  @Binding var text: String
  let minHeight: CGFloat

  @State private var mode: TaskBoardDescriptionPreviewMode = .markdown

  private var hasText: Bool {
    !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      header
      content
    }
  }

  private var header: some View {
    HStack(alignment: .center, spacing: HarnessMonitorTheme.spacingMD) {
      Spacer(minLength: HarnessMonitorTheme.spacingSM)
      HarnessMonitorSegmentedPicker(
        title: "Description mode",
        selection: $mode,
        accessibilityIdentifier: "harness.task-board.manage-item.body.mode"
      ) {
        ForEach(TaskBoardDescriptionPreviewMode.allCases) { mode in
          Text(mode.title)
            .tag(mode)
            .accessibilityIdentifier(mode.accessibilityID)
        }
      }
      .fixedSize()
    }
  }

  @ViewBuilder private var content: some View {
    switch mode {
    case .markdown:
      TaskBoardDescriptionEditor(text: $text, minHeight: minHeight)
    case .rendered:
      ScrollView {
        Group {
          if hasText {
            HarnessMonitorMarkdownText(text, textSelection: .enabled, rendering: mode.rendering)
          } else {
            Text("Add a description to preview it here")
              .scaledFont(.caption)
              .foregroundStyle(HarnessMonitorTheme.secondaryInk)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(HarnessMonitorTheme.spacingSM)
      }
      .frame(
        maxWidth: .infinity, minHeight: minHeight, maxHeight: minHeight, alignment: .topLeading
      )
      .taskBoardManagementFieldChrome()
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("harness.task-board.manage-item.body-preview")
    }
  }
}

struct TaskBoardPlanLifecycleActionButtons: View {
  let item: TaskBoardItem
  let draft: TaskBoardItemEditorDraft
  let metrics: TaskBoardOverviewMetrics
  let isActionInFlight: Bool
  let onBeginPlan: ((TaskBoardItem) -> Void)?
  let onSubmitPlan: ((TaskBoardItem, String) -> Void)?
  let onApprovePlan: ((TaskBoardItem, String, String?) -> Void)?
  let onRevokePlan: ((TaskBoardItem) -> Void)?
  @Environment(\.fontScale)
  private var fontScale
  @State private var isConfirmingRevoke = false

  private var labelFont: Font {
    HarnessMonitorTextSize.scaledFont(.caption.weight(.semibold), by: fontScale)
  }

  // Revoke only makes sense once a plan has been submitted or approved;
  // there is nothing to undo before that.
  private var canRevoke: Bool {
    item.planApprovalState != .notApproved
  }

  var body: some View {
    let labelFont = labelFont
    beginPlanButton(labelFont: labelFont)
    submitPlanButton(labelFont: labelFont)
    approvePlanButton(labelFont: labelFont)
    revokePlanButton(labelFont: labelFont)
  }

  private func revokePlanButton(labelFont: Font) -> some View {
    Button(role: .destructive) {
      isConfirmingRevoke = true
    } label: {
      Label("Revoke Plan", systemImage: "arrow.uturn.backward")
        .font(labelFont)
    }
    .frame(minHeight: metrics.controlMinHeight)
    .harnessActionButtonStyle(variant: .bordered, tint: HarnessMonitorTheme.caution)
    .controlSize(HarnessMonitorControlMetrics.compactControlSize)
    .disabled(isActionInFlight || onRevokePlan == nil || !canRevoke)
    .help("Revoke this plan and return the item to unapproved planning")
    .accessibilityIdentifier("harness.task-board.manage-item.revoke-plan")
    .confirmationDialog(
      "Revoke this plan?",
      isPresented: $isConfirmingRevoke,
      titleVisibility: .visible
    ) {
      Button("Revoke Plan", role: .destructive) {
        onRevokePlan?(item)
      }
      .disabled(isActionInFlight || onRevokePlan == nil || !canRevoke)
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("The plan summary and any approval are cleared. This cannot be undone.")
    }
  }

  private func beginPlanButton(labelFont: Font) -> some View {
    Button {
      onBeginPlan?(item)
    } label: {
      Label("Begin Plan", systemImage: "pencil.and.list.clipboard")
        .font(labelFont)
    }
    .frame(minHeight: metrics.controlMinHeight)
    .harnessActionButtonStyle(variant: .bordered, tint: HarnessMonitorTheme.accent)
    .controlSize(HarnessMonitorControlMetrics.compactControlSize)
    .disabled(isActionInFlight || onBeginPlan == nil)
    .help("Move this board item into planning")
    .accessibilityIdentifier("harness.task-board.manage-item.begin-plan")
  }

  private func submitPlanButton(labelFont: Font) -> some View {
    Button {
      guard let summary = draft.planSummaryForSubmit else { return }
      onSubmitPlan?(item, summary)
    } label: {
      Label("Submit Plan", systemImage: "paperplane")
        .font(labelFont)
    }
    .frame(minHeight: metrics.controlMinHeight)
    .harnessActionButtonStyle(variant: .bordered, tint: HarnessMonitorTheme.accent)
    .controlSize(HarnessMonitorControlMetrics.compactControlSize)
    .disabled(isActionInFlight || onSubmitPlan == nil || draft.planSummaryForSubmit == nil)
    .help("Submit this plan for review")
    .accessibilityIdentifier("harness.task-board.manage-item.submit-plan")
  }

  private func approvePlanButton(labelFont: Font) -> some View {
    Button {
      guard let approvedBy = draft.approverForApproval else { return }
      onApprovePlan?(item, approvedBy, draft.approvalTimestampForRequest)
    } label: {
      Label("Approve Plan", systemImage: "checkmark.seal")
        .font(labelFont)
    }
    .frame(minHeight: metrics.controlMinHeight)
    .harnessActionButtonStyle(variant: .bordered, tint: HarnessMonitorTheme.accent)
    .controlSize(HarnessMonitorControlMetrics.compactControlSize)
    .disabled(isActionInFlight || onApprovePlan == nil || draft.approverForApproval == nil)
    .help("Approve this plan")
    .accessibilityIdentifier("harness.task-board.manage-item.approve-plan")
  }
}

extension TaskBoardWorkflowStatus {
  var title: String {
    switch self {
    case .idle:
      "Idle"
    case .running:
      "Running"
    case .paused:
      "Paused"
    case .completed:
      "Completed"
    case .failed:
      "Failed"
    case .cancelled:
      "Cancelled"
    }
  }
}
