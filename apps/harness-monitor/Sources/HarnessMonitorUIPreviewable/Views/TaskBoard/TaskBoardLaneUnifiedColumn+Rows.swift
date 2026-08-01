import HarnessMonitorKit
import SwiftUI

extension TaskBoardLaneUnifiedColumn {
  func taskBoardListRow(_ row: TaskBoardLaneListRow) -> some View {
    styleListRow(
      ZStack {
        if cardGapState.isActive, let dragged = cardGapState.draggedCardID, row.cardID == dragged {
          taskBoardGapPlaceholder(cardID: dragged, showsMarker: cardGapState.showsMarker)
        } else {
          taskBoardListRowContent(row)
        }
      }
    )
  }

  // The placeholder keeps its draggable identity so the drag container never
  // observes a remove-without-insert. Only the exact target draws the slot.
  private func taskBoardGapPlaceholder(
    cardID: TaskBoardCardID,
    showsMarker: Bool
  ) -> some View {
    Color.clear
      // `styleListRow` adds the measured row's vertical insets back.
      .frame(height: max(1, cardGapState.gapHeight - metrics.laneSpacing))
      .overlay {
        if showsMarker {
          RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusSM)
            .fill(HarnessMonitorTheme.accent.opacity(0.12))
            .overlay {
              RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusSM)
                .strokeBorder(
                  HarnessMonitorTheme.accent.opacity(0.45),
                  style: StrokeStyle(lineWidth: 1.5, dash: [5])
                )
            }
        }
      }
      .draggable(containerItemID: cardID)
  }

  @ViewBuilder
  private func taskBoardListRowContent(_ row: TaskBoardLaneListRow) -> some View {
    switch row {
    case .decision(let decision):
      taskBoardDecisionRow(decision)
    case .api(let item):
      taskBoardAPIRow(item)
    case .inbox(let item):
      taskBoardInboxRow(item)
    }
  }

  private func taskBoardAPIRow(_ item: TaskBoardItem) -> some View {
    let cardID = TaskBoardCardID.api(item.id)
    let hoverID = TaskBoardLaneCardHoverID.api(item.id)
    return TaskBoardItemRow(
      item: item,
      titleTypography: titleTypography,
      isHovered: hoveredCardIDValue == hoverID,
      isSelected: selectionModel.selectedIDs.contains(cardID),
      selectionModel: selectionModel,
      actions: actions,
      cardPresentation: apiCardPresentations[item.id]
    )
    .taskBoardCardFrame(
      id: hoverID,
      in: cardHoverCoordinateSpace,
      tracking: hoverTrackingValue,
      isHovered: hoveredCardIDValue == hoverID,
      onChange: resolveHoveredCard
    )
    .background {
      TaskBoardCardContextMenu(cardID: cardID)
    }
  }

  private func taskBoardInboxRow(_ item: TaskBoardInboxItem) -> some View {
    let cardID = TaskBoardCardID.inbox(
      sessionID: item.session.sessionId,
      taskID: item.task.taskId
    )
    let hoverID = TaskBoardLaneCardHoverID.inbox(
      sessionID: item.session.sessionId,
      taskID: item.task.taskId
    )
    return TaskBoardInboxItemRow(
      item: item,
      titleTypography: titleTypography,
      isHovered: hoveredCardIDValue == hoverID,
      isSelected: selectionModel.selectedIDs.contains(cardID),
      selectionModel: selectionModel,
      actions: actions,
      cardPresentation: inboxCardPresentations[cardID]
    )
    .taskBoardCardFrame(
      id: hoverID,
      in: cardHoverCoordinateSpace,
      tracking: hoverTrackingValue,
      isHovered: hoveredCardIDValue == hoverID,
      onChange: resolveHoveredCard
    )
    .background {
      TaskBoardCardContextMenu(cardID: cardID)
    }
  }

  private func taskBoardDecisionRow(_ decision: Decision) -> some View {
    let hoverID = TaskBoardLaneCardHoverID.decision(decision.id)
    return TaskBoardDecisionRow(
      decision: decision,
      fontScale: fontScale,
      isHovered: hoveredCardIDValue == hoverID,
      actions: actions
    )
    .taskBoardCardFrame(
      id: hoverID,
      in: cardHoverCoordinateSpace,
      tracking: hoverTrackingValue,
      isHovered: hoveredCardIDValue == hoverID,
      onChange: resolveHoveredCard
    )
  }

  private func styleListRow<Content: View>(_ content: Content) -> some View {
    content
      .listRowInsets(
        EdgeInsets(
          top: metrics.laneSpacing / 2,
          leading: metrics.listRowHorizontalInset,
          bottom: metrics.laneSpacing / 2,
          trailing: metrics.listRowHorizontalInset
        )
      )
      .listRowSeparator(.hidden)
      .listRowBackground(Color.clear)
  }

  func updateHoveredCard(phase: HoverPhase) {
    TaskBoardCardDragDiagnostics.recordHoverPhase(lane: lane.rawValue)
    switch phase {
    case .active(let location):
      hoverTrackingValue.location = location
      resolveHoveredCard()
    case .ended:
      hoverTrackingValue.location = nil
      updateHoveredCard(id: nil)
    }
  }

  /// Re-picks from the last pointer location when scrolling moves content
  /// underneath a stationary pointer.
  private func resolveHoveredCard() {
    TaskBoardCardDragDiagnostics.recordHoverResolution(lane: lane.rawValue)
    guard !dragRuntime.isActive else { return }
    guard let location = hoverTrackingValue.location else {
      updateHoveredCard(id: nil)
      return
    }
    updateHoveredCard(id: hoverTrackingValue.cardID(at: location))
  }

  private func updateHoveredCard(id: TaskBoardLaneCardHoverID?) {
    guard hoveredCardIDValue != id else {
      return
    }
    TaskBoardCardDragDiagnostics.recordHoverMutation(lane: lane.rawValue)
    hoveredCardIDValue = id
  }
}
