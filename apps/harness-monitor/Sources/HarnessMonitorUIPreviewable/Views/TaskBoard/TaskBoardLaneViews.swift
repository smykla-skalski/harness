import AppKit
import HarnessMonitorKit
import SwiftUI

struct TaskBoardItemRow: View {
  let item: TaskBoardItem
  let titleTypography: TaskBoardCardTitleTypography
  let isHovered: Bool
  let isSelected: Bool
  let selectionModel: TaskBoardCardSelectionModel
  let actions: TaskBoardOverviewActions
  /// `var` (not `let`): a `let` with a default is excluded from the memberwise init entirely.
  var cardPresentation: TaskBoardCardPresentation?
  @Environment(\.fontScale)
  private var fontScale
  @Environment(\.taskBoardLaneAppearance)
  private var laneAppearance
  @Environment(\.taskBoardShowsPriorityBadge)
  private var showsPriorityBadge
  @Environment(\.taskBoardShowsApprovalBadge)
  private var showsApprovalBadge
  @Environment(\.taskBoardAlwaysShowsFullRepositoryNames)
  private var alwaysShowsFullRepositoryNames
  @Environment(\.taskBoardProjectLabelResolver)
  private var projectLabelResolver

  private var cardID: TaskBoardCardID { .api(item.id) }
  private var metrics: TaskBoardLaneMetrics { TaskBoardLaneMetrics(fontScale: fontScale) }

  /// On-the-fly fallback used only when `cardPresentation` has not been wired in yet.
  private var fallbackTitlePresentation: TaskBoardCardTitlePresentation {
    TaskBoardCardTitlePresentation(item: item)
  }
  private var titleFragments: [TaskBoardInlineCodeFragment] {
    cardPresentation?.titleFragments
      ?? TaskBoardInlineCodeFormatter.fragments(in: fallbackTitlePresentation.title)
  }
  private var titleLeadingText: String? {
    cardPresentation?.titleLeadingText ?? fallbackTitlePresentation.leadingText
  }
  private var titleDisplayText: String {
    cardPresentation?.titleDisplayText
      ?? TaskBoardInlineCodeFormatter.displayText(
        for: titleFragments,
        leadingText: titleLeadingText
      )
  }
  private var updatedAtDate: Date? {
    if let cardPresentation {
      return cardPresentation.updatedAt
    }
    return TaskBoardCardDateParsing.parse(item.updatedAt)
  }

  var body: some View {
    Button {
      selectionModel.select(cardID, modifiers: Self.currentEventModifiers)
      if Self.currentClickCount == 2 {
        selectionModel.openAPIItem(item, actions: actions)
      }
    } label: {
      VStack(alignment: .leading, spacing: metrics.laneSpacing) {
        VStack(alignment: .leading, spacing: metrics.rowTextSpacing) {
          TaskBoardInlineCodeText(
            fragments: titleFragments,
            displayText: titleDisplayText,
            font: titleTypography.font,
            codeFont: titleTypography.codeFont,
            leadingText: titleLeadingText,
            foregroundStyle: HarnessMonitorTheme.ink,
            lineLimit: 2
          )
        }
        TaskBoardCardFooter(repository: repositoryLabel, updatedAt: updatedAtDate) {
          badgeContent
        }
      }
      .frame(
        maxWidth: .infinity,
        alignment: .topLeading
      )
      .padding(metrics.cardPadding)
    }
    .taskBoardCardChrome(tint: cardGlyph.tint, isHovered: isHovered, isSelected: isSelected)
    .contentShape(.rect)
    .draggable(containerItemID: cardID)
    .accessibilityValue(isSelected ? "Selected" : "Not selected")
    .accessibilityHint("Click to select. Double-click to open.")
    .accessibilityAddTraits(isSelected ? .isSelected : [])
    .accessibilityAction(named: Text("Open")) {
      selectionModel.openAPIItem(item, actions: actions)
    }
    .accessibilityIdentifier("harness.task-board.api-item.\(item.id)")
  }

  private var statusTint: Color { taskBoardStatusColor(for: item.status) }

  private var repositoryLabel: String {
    guard let repositoryID = item.taskBoardRepositoryIdentity else {
      return item.agentMode.title
    }
    if let cardPresentation {
      let precomputed =
        alwaysShowsFullRepositoryNames
        ? cardPresentation.repositoryLabelFullName
        : cardPresentation.repositoryLabelDefault
      if let precomputed {
        return precomputed
      }
    }
    return projectLabelResolver.label(
      for: repositoryID,
      alwaysShowFullName: alwaysShowsFullRepositoryNames
    )
  }

  private var cardGlyph: TaskBoardCardGlyph {
    let resolvedGlyph: TaskBoardCardGlyph? =
      if let cardPresentation {
        cardPresentation.glyph
      } else {
        TaskBoardGitHubCardGlyph.resolve(for: item)
      }
    return resolvedGlyph ?? TaskBoardCardGlyph(systemImage: statusSymbol, tint: statusTint)
  }

  private var statusSymbol: String? {
    TaskBoardInboxLane(taskBoardItem: item).flatMap { lane in
      taskBoardLaneSystemImage(for: lane, appearance: laneAppearance)
    }
  }

  @ViewBuilder private var badgeContent: some View {
    if showsPriorityBadge {
      TaskBoardCardPill(label: item.priority.title, tint: priorityColor(for: item.priority))
    }
    if showsApprovalBadge {
      let approvalState = item.planApprovalState
      TaskBoardCardPill(
        label: approvalState.badgeLabel,
        tint: taskBoardApprovalColor(for: approvalState)
      )
      .accessibilityLabel(approvalState.accessibilityLabel)
    }
    if let policyTraceCount = item.workflow?.policyTraceIds.count, policyTraceCount > 0 {
      TaskBoardCardPill(label: "\(policyTraceCount) policy", tint: HarnessMonitorTheme.secondaryInk)
    }
    if case .manual = item.laneOrigin {
      TaskBoardCardPill(
        label: "Manual",
        tint: HarnessMonitorTheme.accent,
        systemImage: "hand.point.up.left.fill"
      )
      .accessibilityLabel("Manually placed in this lane")
    }
  }

  private static var currentEventModifiers: EventModifiers {
    EventModifiers(nsModifiers: NSEvent.modifierFlags)
  }

  private static var currentClickCount: Int {
    NSApp.currentEvent?.clickCount ?? 1
  }
}

struct TaskBoardInboxItemRow: View {
  let item: TaskBoardInboxItem
  let titleTypography: TaskBoardCardTitleTypography
  let isHovered: Bool
  let isSelected: Bool
  let selectionModel: TaskBoardCardSelectionModel
  let actions: TaskBoardOverviewActions
  /// `var` (not `let`): a `let` with a default is excluded from the memberwise init entirely.
  var cardPresentation: TaskBoardCardPresentation?
  @Environment(\.fontScale)
  private var fontScale

  private var metrics: TaskBoardLaneMetrics { TaskBoardLaneMetrics(fontScale: fontScale) }
  private var cardID: TaskBoardCardID {
    .inbox(sessionID: item.session.sessionId, taskID: item.task.taskId)
  }

  private var titleFragments: [TaskBoardInlineCodeFragment] {
    cardPresentation?.titleFragments ?? TaskBoardInlineCodeFormatter.fragments(in: item.task.title)
  }
  private var titleDisplayText: String {
    cardPresentation?.titleDisplayText
      ?? TaskBoardInlineCodeFormatter.displayText(for: titleFragments)
  }
  private var updatedAtDate: Date? {
    if let cardPresentation {
      return cardPresentation.updatedAt
    }
    return TaskBoardCardDateParsing.parse(item.task.updatedAt)
  }

  var body: some View {
    Button {
      selectionModel.select(cardID, modifiers: Self.currentEventModifiers)
      if Self.currentClickCount == 2 {
        actions.openInboxItem(item)
      }
    } label: {
      VStack(alignment: .leading, spacing: metrics.laneSpacing) {
        VStack(alignment: .leading, spacing: metrics.rowTextSpacing) {
          TaskBoardInlineCodeText(
            fragments: titleFragments,
            displayText: titleDisplayText,
            font: titleTypography.font,
            codeFont: titleTypography.codeFont,
            foregroundStyle: HarnessMonitorTheme.ink,
            lineLimit: 2
          )
        }
        TaskBoardCardFooter(repository: item.subtitle, updatedAt: updatedAtDate) {
          badgeContent
        }
      }
      .frame(
        maxWidth: .infinity,
        alignment: .topLeading
      )
      .padding(metrics.cardPadding)
    }
    .taskBoardCardChrome(tint: statusTint, isHovered: isHovered, isSelected: isSelected)
    .contentShape(.rect)
    .draggable(containerItemID: cardID)
    .accessibilityValue(isSelected ? "Selected" : "Not selected")
    .accessibilityHint("Click to select. Double-click to open.")
    .accessibilityAddTraits(isSelected ? .isSelected : [])
    .accessibilityAction(named: Text("Open")) {
      actions.openInboxItem(item)
    }
    .accessibilityIdentifier("harness.task-board.item.\(item.task.taskId)")
  }

  private var statusTint: Color { taskStatusColor(for: item.task.status) }

  @ViewBuilder private var badgeContent: some View {
    TaskBoardCardPill(label: item.task.status.title, tint: statusTint)
    TaskBoardCardPill(label: item.task.severity.title, tint: severityColor(for: item.task.severity))
  }

  private static var currentEventModifiers: EventModifiers {
    EventModifiers(nsModifiers: NSEvent.modifierFlags)
  }

  private static var currentClickCount: Int {
    NSApp.currentEvent?.clickCount ?? 1
  }
}
