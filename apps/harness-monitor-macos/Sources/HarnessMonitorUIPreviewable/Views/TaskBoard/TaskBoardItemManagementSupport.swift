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

struct TaskBoardPlanLifecycleActionButtons: View {
  let item: TaskBoardItem
  let draft: TaskBoardItemEditorDraft
  let metrics: TaskBoardOverviewMetrics
  let isActionInFlight: Bool
  let onBeginPlan: ((TaskBoardItem) -> Void)?
  let onSubmitPlan: ((TaskBoardItem, String) -> Void)?
  let onApprovePlan: ((TaskBoardItem, String, String?) -> Void)?
  @Environment(\.fontScale)
  private var fontScale

  private var labelFont: Font {
    HarnessMonitorTextSize.scaledFont(.caption.weight(.semibold), by: fontScale)
  }

  var body: some View {
    let labelFont = labelFont
    beginPlanButton(labelFont: labelFont)
    submitPlanButton(labelFont: labelFont)
    approvePlanButton(labelFont: labelFont)
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
