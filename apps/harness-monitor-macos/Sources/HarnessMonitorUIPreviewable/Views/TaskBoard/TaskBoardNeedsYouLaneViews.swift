import Foundation
import HarnessMonitorKit
import SwiftUI

struct TaskBoardNeedsYouLaneColumn: View {
  let section: TaskBoardItemSection
  let decisions: [Decision]
  let onOpenItem: (TaskBoardItem) -> Void
  let onMoveItem: (String, TaskBoardInboxLane) -> Bool
  let onOpenDecision: (Decision) -> Void
  @Environment(\.fontScale)
  private var fontScale
  @State private var isDropTargeted = false
  @State private var dropDeduper = TaskBoardDropDeduper<TaskBoardItemDropSignature>()

  private var metrics: TaskBoardLaneMetrics { TaskBoardLaneMetrics(fontScale: fontScale) }

  private var itemCount: Int {
    section.items.count + decisions.count
  }

  var body: some View {
    VStack(alignment: .leading, spacing: metrics.laneSpacing) {
      TaskBoardLaneHeader(lane: .needsYou, count: itemCount)

      Group {
        if section.items.isEmpty && decisions.isEmpty {
          TaskBoardEmptyLane(lane: .needsYou)
        } else {
          VStack(spacing: metrics.laneSpacing) {
            ForEach(decisions, id: \.id) { decision in
              TaskBoardDecisionRow(decision: decision, onOpenDecision: onOpenDecision)
            }
            ForEach(section.items) { item in
              TaskBoardItemRow(item: item, onOpenItem: onOpenItem)
            }
          }
        }
      }
      .taskBoardLaneBodyChrome(lane: .needsYou, isDropTargeted: isDropTargeted)
    }
    .taskBoardLaneColumnChrome(lane: .needsYou, isDropTargeted: isDropTargeted)
    .dropDestination(for: TaskBoardItemDragPayload.self, action: handleDrop) { targeted in
      updateDropTargeted(targeted)
    }
    .onDrop(of: [.harnessMonitorTaskBoardItem], isTargeted: nil, perform: handleLegacyDrop)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("harness.task-board.needs-you-column")
  }

  private func handleDrop(_ payloads: [TaskBoardItemDragPayload], _: CGPoint) -> Bool {
    guard let payload = payloads.first else {
      return false
    }
    return performDrop(
      signature: TaskBoardItemDropSignature(itemID: payload.itemID, destination: .needsYou)
    ) {
      TaskBoardLaneDropPolicy.moveFirstPayload(
        payloads,
        to: .needsYou,
        move: onMoveItem
      )
    }
  }

  private func handleLegacyDrop(_ providers: [NSItemProvider]) -> Bool {
    TaskBoardItemDragPayload.loadFirst(from: providers) { payload in
      _ = handleDrop([payload], .zero)
    }
  }

  private func updateDropTargeted(_ targeted: Bool) {
    isDropTargeted = targeted
    if !targeted {
      dropDeduper = TaskBoardDropDeduper()
    }
  }

  private func performDrop(
    signature: TaskBoardItemDropSignature,
    action: () -> Bool
  ) -> Bool {
    var deduper = dropDeduper
    let handled = deduper.perform(signature, move: action)
    dropDeduper = deduper
    return handled
  }
}

struct TaskBoardDecisionRow: View {
  let decision: Decision
  let onOpenDecision: (Decision) -> Void
  private let primaryActionTitle: String
  @Environment(\.fontScale)
  private var fontScale

  private var metrics: TaskBoardLaneMetrics { TaskBoardLaneMetrics(fontScale: fontScale) }

  init(decision: Decision, onOpenDecision: @escaping (Decision) -> Void) {
    self.decision = decision
    self.onOpenDecision = onOpenDecision
    primaryActionTitle = Self.resolvePrimaryActionTitle(for: decision)
  }

  var body: some View {
    Button {
      onOpenDecision(decision)
    } label: {
      VStack(alignment: .leading, spacing: metrics.laneSpacing) {
        HStack(alignment: .top, spacing: metrics.laneSpacing) {
          TaskBoardCardLeadingIcon(
            systemImage: "person.crop.circle.badge.exclamationmark",
            tint: severityColor
          )
          .padding(.top, metrics.cardMarkerTopPadding)
          VStack(alignment: .leading, spacing: metrics.rowTextSpacing) {
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
        ViewThatFits(in: .horizontal) {
          HStack(spacing: metrics.laneBodyTopPadding) {
            badgeContent
          }
          VStack(alignment: .leading, spacing: metrics.laneBodyTopPadding) {
            badgeContent
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .frame(minHeight: metrics.cardMinHeight, alignment: .topLeading)
      .padding(metrics.cardPadding)
    }
    .taskBoardCardChrome()
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

  @ViewBuilder private var badgeContent: some View {
    TaskBoardCardPill(label: "Decision", tint: severityColor)
    if let scopeLabel {
      TaskBoardCardPill(label: scopeLabel, tint: HarnessMonitorTheme.secondaryInk)
    }
    TaskBoardCardPill(label: primaryActionTitle, tint: HarnessMonitorTheme.accent)
  }

  private static func resolvePrimaryActionTitle(for decision: Decision) -> String {
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
}
