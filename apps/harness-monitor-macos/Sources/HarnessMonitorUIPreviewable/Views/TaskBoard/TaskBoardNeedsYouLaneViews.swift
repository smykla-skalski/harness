import Foundation
import HarnessMonitorKit
import SwiftUI

@MainActor private let taskBoardDecisionAgeFormatter: RelativeDateTimeFormatter = {
  let formatter = RelativeDateTimeFormatter()
  formatter.locale = .autoupdatingCurrent
  formatter.unitsStyle = .abbreviated
  return formatter
}()

/// Decoder shared by `TaskBoardDecisionRow.resolvePrimaryAction(for:)`, which
/// runs from the per-row init. A fresh `JSONDecoder()` per init shows up as
/// steady-state churn while the lane re-renders.
private let taskBoardNeedsYouSuggestedActionsDecoder = JSONDecoder()

struct TaskBoardDecisionRow: View {
  let decision: Decision
  let onOpenDecision: (Decision) -> Void
  private let primaryAction: SuggestedAction?
  private let metrics: TaskBoardLaneMetrics
  private let summaryFont: Font
  private let summaryCodeFont: Font
  private let ruleFont: Font
  private let actionFont: Font
  private let actionCodeFont: Font
  private let chevronFont: Font

  init(
    decision: Decision,
    fontScale: CGFloat,
    onOpenDecision: @escaping (Decision) -> Void
  ) {
    self.decision = decision
    self.onOpenDecision = onOpenDecision
    primaryAction = Self.resolvePrimaryAction(for: decision)
    metrics = TaskBoardLaneMetrics(fontScale: fontScale)
    summaryFont = HarnessMonitorTextSize.scaledFont(.caption, by: fontScale)
    summaryCodeFont = HarnessMonitorTextSize.scaledFont(.caption.monospaced(), by: fontScale)
    ruleFont = HarnessMonitorTextSize.scaledFont(
      .subheadline.weight(.semibold),
      by: fontScale
    )
    actionFont = HarnessMonitorTextSize.scaledFont(
      .caption.weight(.semibold),
      by: fontScale
    )
    actionCodeFont = HarnessMonitorTextSize.scaledFont(
      .caption.monospaced().weight(.semibold),
      by: fontScale
    )
    chevronFont = HarnessMonitorTextSize.scaledFont(
      .caption2.weight(.semibold),
      by: fontScale
    )
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
        TaskBoardInlineCodeText(
          decision.summary,
          font: summaryFont,
          codeFont: summaryCodeFont,
          foregroundStyle: HarnessMonitorTheme.secondaryInk,
          lineLimit: 3
        )
      }
      if let primaryAction {
        primaryActionRow(for: primaryAction)
      }
    }
    .frame(
      maxWidth: .infinity,
      alignment: .topLeading
    )
    .padding(metrics.cardPadding)
    .taskBoardCardBackgroundGlyph(
      systemImage: severitySystemImage,
      tint: severityColor,
      cornerRadius: metrics.cardCornerRadius
    )
  }

  private var headerRow: some View {
    HStack(alignment: .top, spacing: metrics.laneSpacing) {
      VStack(alignment: .leading, spacing: 2) {
        Text(ruleDisplayName)
          .font(ruleFont)
          .foregroundStyle(HarnessMonitorTheme.ink)
          .lineLimit(1)
          .truncationMode(.tail)
        TaskBoardDecisionScopeLine(
          staticScope: staticScopePart,
          createdAt: decision.createdAt,
          font: summaryFont
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
        .font(actionFont)
      TaskBoardInlineCodeText(
        action.title,
        font: actionFont,
        codeFont: actionCodeFont,
        foregroundStyle: actionTint(for: action.kind),
        codeForeground: actionTint(for: action.kind),
        lineLimit: 1
      )
      Spacer(minLength: 0)
      Image(systemName: "chevron.right")
        .font(chevronFont)
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
      let actions = try? taskBoardNeedsYouSuggestedActionsDecoder.decode(
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
      pieces.append(TaskBoardInlineCodeFormatter.displayText(for: decision.summary))
    }
    return pieces.joined(separator: ", ")
  }

  private var accessibilityHint: String {
    if let primaryAction {
      return """
        Activate to review. Suggested action: \
        \(TaskBoardInlineCodeFormatter.displayText(for: primaryAction.title)).
        """
    }
    return "Activate to review"
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
  let font: Font

  var body: some View {
    TimelineView(.periodic(from: .now, by: 15)) { context in
      Text(combined(now: context.date))
        .font(font)
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
