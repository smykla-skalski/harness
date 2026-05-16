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

  var body: some View {
    Grid(alignment: .leading, horizontalSpacing: HarnessMonitorTheme.spacingMD) {
      ForEach(facts) { fact in
        GridRow {
          Text(fact.label)
            .scaledFont(.caption.weight(.semibold))
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          Text(fact.value)
            .scaledFont(.caption)
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

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: HarnessMonitorTheme.spacingSM) { links }
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) { links }
    }
  }

  @ViewBuilder private var links: some View {
    ForEach(destinations) { destination in
      Link(destination: destination.url) {
        Label(destination.label, systemImage: "arrow.up.right.square")
          .scaledFont(.caption.weight(.semibold))
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

  var body: some View {
    beginPlanButton
    submitPlanButton
    approvePlanButton
  }

  private var beginPlanButton: some View {
    Button {
      onBeginPlan?(item)
    } label: {
      Label("Begin Plan", systemImage: "pencil.and.list.clipboard")
        .scaledFont(.caption.weight(.semibold))
    }
    .frame(minHeight: metrics.controlMinHeight)
    .harnessActionButtonStyle(variant: .bordered, tint: HarnessMonitorTheme.accent)
    .controlSize(HarnessMonitorControlMetrics.compactControlSize)
    .disabled(isActionInFlight || onBeginPlan == nil)
    .help("Move this board item into planning")
    .accessibilityIdentifier("harness.task-board.manage-item.begin-plan")
  }

  private var submitPlanButton: some View {
    Button {
      guard let summary = draft.planSummaryForSubmit else { return }
      onSubmitPlan?(item, summary)
    } label: {
      Label("Submit Plan", systemImage: "paperplane")
        .scaledFont(.caption.weight(.semibold))
    }
    .frame(minHeight: metrics.controlMinHeight)
    .harnessActionButtonStyle(variant: .bordered, tint: HarnessMonitorTheme.accent)
    .controlSize(HarnessMonitorControlMetrics.compactControlSize)
    .disabled(isActionInFlight || onSubmitPlan == nil || draft.planSummaryForSubmit == nil)
    .help("Submit this plan for review")
    .accessibilityIdentifier("harness.task-board.manage-item.submit-plan")
  }

  private var approvePlanButton: some View {
    Button {
      guard let approvedBy = draft.approverForApproval else { return }
      onApprovePlan?(item, approvedBy, draft.approvalTimestampForRequest)
    } label: {
      Label("Approve Plan", systemImage: "checkmark.seal")
        .scaledFont(.caption.weight(.semibold))
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
