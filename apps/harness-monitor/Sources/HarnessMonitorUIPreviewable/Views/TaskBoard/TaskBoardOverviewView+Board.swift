import HarnessMonitorKit
import SwiftUI

extension TaskBoardOverviewView {
  @ViewBuilder var boardContent: some View {
    if hasBoardContent {
      taskBoardColumns
    } else {
      emptyState
    }
  }

  var taskBoardColumns: some View {
    let titleTypography = TaskBoardCardTitleTypography(fontScale: fontScale)
    return ViewThatFits(in: .horizontal) {
      taskBoardLaneStrip(titleTypography: titleTypography)

      ScrollView(.horizontal, showsIndicators: true) {
        taskBoardLaneStrip(titleTypography: titleTypography)
      }
      .scrollClipDisabled()
    }
    .taskBoardCardDragContainer(
      isEnabled: !isActionInFlight,
      selectedIDs: orderedSelectedCardIDs,
      payloads: cardDragPayloads,
      onSessionUpdated: updateCardDragSession
    )
  }

  func taskBoardLaneStrip(
    titleTypography: TaskBoardCardTitleTypography
  ) -> some View {
    TaskBoardLaneStripLayout(sizing: laneStripSizing) {
      taskBoardLaneColumns(titleTypography: titleTypography)
    }
    .padding(.vertical, metrics.boardVerticalPadding)
  }

  @ViewBuilder
  func taskBoardLaneColumns(titleTypography: TaskBoardCardTitleTypography) -> some View {
    ForEach(TaskBoardInboxLane.allCases) { lane in
      let apiItems = currentPresentation.apiItems(in: lane)
      let inboxItems = currentPresentation.inboxItems(in: lane)
      let decisions = decisions(in: lane)
      let contentCount = laneContentCount(
        apiItems: apiItems,
        inboxItems: inboxItems,
        decisions: decisions
      )
      let isCollapsed = isLaneCollapsed(lane, contentCount: contentCount)
      TaskBoardLaneUnifiedColumn(
        lane: lane,
        apiItems: apiItems,
        inboxItems: inboxItems,
        decisions: decisions,
        titleTypography: titleTypography,
        isCollapsed: isCollapsed,
        selectedCardIDs: cardSelectionValue.selectedIDs,
        onOpenAPIItem: openTaskBoardItem,
        onOpenInboxItem: onOpenItem,
        onOpenDecision: onOpenDecision,
        onToggleCollapse: {
          toggleLaneCollapse(lane, contentCount: contentCount)
        },
        onSelectCard: selectCard,
        onMoveCards: moveCards
      )
      .layoutValue(
        key: TaskBoardLanePreferredWidthKey.self,
        value: isCollapsed ? laneMetrics.laneCollapsedWidth : laneMetrics.laneWidth
      )
      .layoutValue(key: TaskBoardLaneCanExpandKey.self, value: !isCollapsed)
    }
  }

  var emptyState: some View {
    ContentUnavailableView("No Open Tasks", systemImage: "tray")
      .font(bodyFont)
      .frame(maxWidth: .infinity, minHeight: 180)
      .background(
        .background.opacity(0.45), in: .rect(cornerRadius: HarnessMonitorTheme.cornerRadiusSM))
  }

  func decisions(in lane: TaskBoardInboxLane) -> [Decision] {
    currentPresentation.decisionIDs(in: lane).compactMap { decisionsByID[$0] }
  }
}
