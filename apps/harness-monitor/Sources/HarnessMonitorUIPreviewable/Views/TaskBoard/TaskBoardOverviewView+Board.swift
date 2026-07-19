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
    .dragContainer(for: TaskBoardCardDragPayload.self, itemID: \.id) { cardIDs in
      isActionInFlight ? [] : cardDragPayloads(cardIDs)
    }
    .dragContainerSelection(isActionInFlight ? [] : orderedSelectedCardIDs)
    .dragConfiguration(.init(allowMove: !isActionInFlight))
    .dragPreviewsFormation(.pile)
    .onDragSessionUpdated { session in
      guard !isActionInFlight else { return }
      updateCardDragSession(session)
    }
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
        apiCardPresentations: currentPresentation.apiCardPresentations(in: lane),
        inboxCardPresentations: currentPresentation.inboxCardPresentations(in: lane),
        titleTypography: titleTypography,
        isCollapsed: isCollapsed,
        isDropEnabled: !isActionInFlight,
        isDropCandidate: !isActionInFlight && dropCandidateLanesValue.contains(lane),
        selectionModel: selectionModelValue,
        actions: actions,
        contextMenuActions: taskBoardCardContextMenuActions,
        collapseOverridesRawValue: laneCollapsePreferencesRawValueBinding
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
