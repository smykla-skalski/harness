import Foundation
import HarnessMonitorKit
import SwiftUI

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

  init(
    decision: Decision,
    onOpenDecision: @escaping (Decision) -> Void
  ) {
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
        TaskBoardDecisionScopeLine(
          staticScope: staticScopePart,
          createdAt: decision.createdAt
        )
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

  private var staticScopePart: String {
    var parts: [String] = []
    if let agentID = decision.agentID, !agentID.isEmpty {
      parts.append("Agent \(humanizedWorkspaceLabel(agentID))")
    }
    if let taskID = decision.taskID, !taskID.isEmpty {
      parts.append("Task \(humanizedWorkspaceLabel(taskID))")
    } else if let sessionID = decision.sessionID, !sessionID.isEmpty {
      parts.append("Session \(humanizedWorkspaceLabel(sessionID))")
    }
    return parts.joined(separator: " · ")
  }

  static func relativeAge(now: Date, createdAt: Date) -> String {
    let interval = now.timeIntervalSince(createdAt)
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
    pieces.append("queued \(Self.relativeAge(now: .now, createdAt: decision.createdAt))")
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

/// Time-dependent text isolated behind its own 15s `TimelineView` so the
/// surrounding decision row body does not re-evaluate on every clock tick.
/// "5m ago" granularity does not need second-level precision; 15s keeps the
/// reading fresh enough for a human glance while collapsing the lane-wide
/// `External: Time -> Text` fanout that previously hit ~80 updates/second.
private struct TaskBoardDecisionScopeLine: View {
  let staticScope: String
  let createdAt: Date

  var body: some View {
    TimelineView(.periodic(from: .now, by: 15)) { context in
      Text(combined(now: context.date))
        .scaledFont(.caption)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .lineLimit(1)
        .truncationMode(.tail)
    }
  }

  private func combined(now: Date) -> String {
    let age = TaskBoardDecisionRow.relativeAge(now: now, createdAt: createdAt)
    return staticScope.isEmpty ? age : "\(staticScope) · \(age)"
  }
}
