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

@MainActor private let taskBoardDecisionAgeFormatter: RelativeDateTimeFormatter = {
  let formatter = RelativeDateTimeFormatter()
  formatter.locale = .autoupdatingCurrent
  formatter.unitsStyle = .abbreviated
  return formatter
}()

struct TaskBoardDecisionRow: View {
  let decision: Decision
  let onOpenDecision: (Decision) -> Void
  private let primaryAction: SuggestedAction?
  @Environment(\.fontScale)
  private var fontScale

  private var metrics: TaskBoardLaneMetrics { TaskBoardLaneMetrics(fontScale: fontScale) }

  init(decision: Decision, onOpenDecision: @escaping (Decision) -> Void) {
    self.decision = decision
    self.onOpenDecision = onOpenDecision
    primaryAction = Self.resolvePrimaryAction(for: decision)
  }

  var body: some View {
    Button {
      onOpenDecision(decision)
    } label: {
      cardBody
    }
    .taskBoardCardChrome()
    .help("Open decision")
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityHint(accessibilityHint)
    .accessibilityAddTraits(.isButton)
    .accessibilityIdentifier("harness.task-board.decision.\(decision.id)")
  }

  private var cardBody: some View {
    VStack(alignment: .leading, spacing: metrics.rowTextSpacing) {
      headerRow
      if !decision.summary.isEmpty {
        Text(decision.summary)
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .lineLimit(3)
          .multilineTextAlignment(.leading)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      if let primaryAction {
        primaryActionRow(for: primaryAction)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .frame(minHeight: metrics.cardMinHeight, alignment: .topLeading)
    .padding(metrics.cardPadding)
  }

  private var headerRow: some View {
    HStack(alignment: .top, spacing: metrics.laneSpacing) {
      TaskBoardCardLeadingIcon(systemImage: severitySystemImage, tint: severityColor)
        .padding(.top, metrics.cardMarkerTopPadding)
      VStack(alignment: .leading, spacing: 2) {
        Text(ruleDisplayName)
          .scaledFont(.subheadline.weight(.semibold))
          .foregroundStyle(HarnessMonitorTheme.ink)
          .lineLimit(1)
          .truncationMode(.tail)
        Text(scopeLine)
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .lineLimit(1)
          .truncationMode(.tail)
      }
      Spacer(minLength: metrics.laneSpacing)
      TaskBoardCardPill(label: severity.chipLabel, tint: severityColor)
        .layoutPriority(1)
    }
  }

  @ViewBuilder
  private func primaryActionRow(for action: SuggestedAction) -> some View {
    HStack(spacing: HarnessMonitorTheme.spacingXS) {
      Image(systemName: actionSymbol(for: action.kind))
        .scaledFont(.caption.weight(.semibold))
      Text(action.title)
        .scaledFont(.caption.weight(.semibold))
        .lineLimit(1)
      Spacer(minLength: 0)
      Image(systemName: "chevron.right")
        .scaledFont(.caption2.weight(.semibold))
        .opacity(0.7)
    }
    .foregroundStyle(actionTint(for: action.kind))
    .padding(.horizontal, metrics.pillHorizontalPadding)
    .padding(.vertical, metrics.pillVerticalPadding + 2)
    .frame(maxWidth: .infinity, alignment: .leading)
    .harnessContentPill(tint: actionTint(for: action.kind))
    .padding(.top, 2)
  }

  private var severity: DecisionSeverity {
    DecisionSeverity(rawValue: decision.severityRaw) ?? .info
  }

  private var severityColor: Color { severity.chipColor }

  private var severitySystemImage: String {
    switch severity {
    case .critical: "exclamationmark.octagon.fill"
    case .needsUser: "person.fill.questionmark"
    case .warn: "exclamationmark.triangle.fill"
    case .info: "info.circle.fill"
    }
  }

  private var ruleDisplayName: String {
    humanizedWorkspaceLabel(decision.ruleID)
  }

  private var scopeLine: String {
    var parts: [String] = []
    if let agentID = decision.agentID, !agentID.isEmpty {
      parts.append("Agent \(humanizedWorkspaceLabel(agentID))")
    }
    if let taskID = decision.taskID, !taskID.isEmpty {
      parts.append("Task \(humanizedWorkspaceLabel(taskID))")
    } else if let sessionID = decision.sessionID, !sessionID.isEmpty {
      parts.append("Session \(humanizedWorkspaceLabel(sessionID))")
    }
    parts.append(relativeAge)
    return parts.joined(separator: " · ")
  }

  private var relativeAge: String {
    let interval = Date.now.timeIntervalSince(decision.createdAt)
    return taskBoardDecisionAgeFormatter.localizedString(fromTimeInterval: -interval)
  }

  private func actionSymbol(for kind: SuggestedAction.Kind) -> String {
    switch kind {
    case .nudge: "bell.badge"
    case .assignTask: "arrow.forward.circle"
    case .dropTask: "trash"
    case .snooze: "moon.zzz"
    case .dismiss: "xmark.circle"
    case .custom: "wrench.adjustable"
    }
  }

  private func actionTint(for kind: SuggestedAction.Kind) -> Color {
    switch kind {
    case .dismiss: HarnessMonitorTheme.danger
    case .snooze: HarnessMonitorTheme.caution
    default: HarnessMonitorTheme.accent
    }
  }

  private static func resolvePrimaryAction(for decision: Decision) -> SuggestedAction? {
    guard
      let actions = try? JSONDecoder().decode(
        [SuggestedAction].self,
        from: Data(decision.suggestedActionsJSON.utf8)
      ),
      !actions.isEmpty
    else {
      return nil
    }
    return actions.first { isProminent($0) } ?? actions.first
  }

  private static func isProminent(_ action: SuggestedAction) -> Bool {
    switch action.kind {
    case .dismiss, .snooze: false
    default: true
    }
  }

  private var accessibilityLabel: String {
    var pieces: [String] = ["\(severity.chipLabel) decision", ruleDisplayName]
    if let agentID = decision.agentID, !agentID.isEmpty {
      pieces.append("agent \(humanizedWorkspaceLabel(agentID))")
    }
    if let taskID = decision.taskID, !taskID.isEmpty {
      pieces.append("task \(humanizedWorkspaceLabel(taskID))")
    } else if let sessionID = decision.sessionID, !sessionID.isEmpty {
      pieces.append("session \(humanizedWorkspaceLabel(sessionID))")
    }
    pieces.append("queued \(relativeAge)")
    if !decision.summary.isEmpty {
      pieces.append(decision.summary)
    }
    return pieces.joined(separator: ", ")
  }

  private var accessibilityHint: String {
    if let primaryAction {
      return "Activate to review. Suggested action: \(primaryAction.title)."
    }
    return "Activate to review."
  }
}
