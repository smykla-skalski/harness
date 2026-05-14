import Foundation
import HarnessMonitorKit
import SwiftUI

struct TaskBoardNeedsYouLaneColumn: View {
  let section: TaskBoardItemSection
  let decisions: [Decision]
  let onOpenItem: (TaskBoardItem) -> Void
  let onMoveItem: (String, TaskBoardInboxLane) -> Bool
  let onOpenDecision: (Decision) -> Void
  @State private var isDropTargeted = false

  private var itemCount: Int {
    section.items.count + decisions.count
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      TaskBoardLaneHeader(lane: .needsYou, count: itemCount)

      Group {
        if section.items.isEmpty && decisions.isEmpty {
          TaskBoardEmptyLane(lane: .needsYou)
        } else {
          VStack(spacing: HarnessMonitorTheme.spacingSM) {
            ForEach(decisions.prefix(4), id: \.id) { decision in
              TaskBoardDecisionRow(decision: decision, onOpenDecision: onOpenDecision)
            }
            ForEach(section.items.prefix(5)) { item in
              TaskBoardItemRow(item: item, onOpenItem: onOpenItem)
            }
            TaskBoardLaneOverflowRow(hiddenCount: hiddenItemCount)
          }
        }
      }
      .taskBoardLaneBodyChrome(lane: .needsYou, isDropTargeted: isDropTargeted)
    }
    .taskBoardLaneColumnChrome(lane: .needsYou)
    .dropDestination(for: TaskBoardItemDragPayload.self, action: handleDrop) { targeted in
      isDropTargeted = targeted
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("harness.task-board.needs-you-column")
  }

  private func handleDrop(_ payloads: [TaskBoardItemDragPayload], _: CGPoint) -> Bool {
    guard let payload = payloads.first else {
      return false
    }
    guard payload.sourceLane != .needsYou else {
      return false
    }
    return onMoveItem(payload.itemID, .needsYou)
  }

  private var hiddenItemCount: Int {
    max(0, decisions.count - 4) + max(0, section.items.count - 5)
  }
}

struct TaskBoardDecisionRow: View {
  let decision: Decision
  let onOpenDecision: (Decision) -> Void

  var body: some View {
    Button {
      onOpenDecision(decision)
    } label: {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
        HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingSM) {
          Image(systemName: "person.crop.circle.badge.exclamationmark")
            .foregroundStyle(severityColor)
            .frame(width: 16)
            .padding(.top, 1)
          VStack(alignment: .leading, spacing: 3) {
            Text(decision.summary)
              .scaledFont(.subheadline.weight(.semibold))
              .foregroundStyle(HarnessMonitorTheme.ink)
              .lineLimit(2)
              .multilineTextAlignment(.leading)
            Text(decision.ruleID)
              .scaledFont(.caption)
              .foregroundStyle(HarnessMonitorTheme.secondaryInk)
              .lineLimit(1)
              .truncationMode(.middle)
          }
          Spacer(minLength: 0)
        }
        HStack(spacing: HarnessMonitorTheme.spacingXS) {
          taskPill("Decision", color: severityColor)
          if let scope = scopeLabel {
            taskPill(scope, color: HarnessMonitorTheme.secondaryInk)
          }
          taskPill(primaryActionTitle, color: HarnessMonitorTheme.accent)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .frame(minHeight: 86, alignment: .topLeading)
      .padding(HarnessMonitorTheme.spacingMD)
    }
    .harnessInteractiveCardButtonStyle(cornerRadius: 8)
    .background(.background.opacity(0.56), in: .rect(cornerRadius: 8))
    .overlay(alignment: .leading) {
      Rectangle()
        .fill(severityColor.opacity(0.82))
        .frame(width: 3)
        .clipShape(.rect(topLeadingRadius: 8, bottomLeadingRadius: 8))
    }
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .stroke(HarnessMonitorTheme.danger.opacity(0.45), lineWidth: 1)
    )
    .accessibilityIdentifier("harness.task-board.decision.\(decision.id)")
  }

  private var severityColor: Color {
    switch DecisionSeverity(rawValue: decision.severityRaw) {
    case .critical:
      HarnessMonitorTheme.danger
    case .needsUser:
      HarnessMonitorTheme.caution
    case .warn:
      HarnessMonitorTheme.warmAccent
    case .info, nil:
      HarnessMonitorTheme.secondaryInk
    }
  }

  private var scopeLabel: String? {
    if decision.taskID != nil {
      return "Task"
    }
    if decision.agentID != nil {
      return "Agent"
    }
    if decision.sessionID != nil {
      return "Session"
    }
    return nil
  }

  private var primaryActionTitle: String {
    guard
      let actions = try? JSONDecoder().decode(
        [SuggestedAction].self,
        from: Data(decision.suggestedActionsJSON.utf8)
      )
    else {
      return "Open"
    }
    return actions.first?.title ?? "Open"
  }

  private func taskPill(_ label: String, color: Color) -> some View {
    Text(label)
      .scaledFont(.caption2.weight(.bold))
      .foregroundStyle(color)
      .lineLimit(1)
      .padding(.horizontal, 9)
      .padding(.vertical, 4)
      .background(color.opacity(0.16), in: .capsule)
  }
}
