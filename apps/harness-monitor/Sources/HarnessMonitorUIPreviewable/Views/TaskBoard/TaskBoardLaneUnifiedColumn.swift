import Foundation
import HarnessMonitorKit
import SwiftUI

struct TaskBoardLaneUnifiedColumn: View {
  let lane: TaskBoardInboxLane
  let apiItems: [TaskBoardItem]
  let inboxItems: [TaskBoardInboxItem]
  let decisions: [Decision]
  let titleTypography: TaskBoardCardTitleTypography
  let isCollapsed: Bool
  let isDropEnabled: Bool
  let isDropCandidate: Bool
  let selectionModel: TaskBoardCardSelectionModel
  let actions: TaskBoardOverviewActions
  let contextMenuActions: TaskBoardCardContextMenuActions
  @Binding var collapseOverridesRawValue: String
  @Environment(\.fontScale)
  private var fontScale
  @State private var isDropTargeted = false
  @State private var dropDeduper = TaskBoardDropDeduper<TaskBoardCardDropSignature>()
  @State private var perfScrollPosition = ScrollPosition()
  @State private var hoverTracking = TaskBoardLaneHoverTracking()
  @State private var hoveredCardID: TaskBoardLaneCardHoverID?
  private let perfScrollHookEnabled = HarnessMonitorPerfTaskBoardLaneScrollBus.isActiveAtLaunch

  private var metrics: TaskBoardLaneMetrics { TaskBoardLaneMetrics(fontScale: fontScale) }
  private var cardHoverCoordinateSpace: String {
    "task-board-lane-card-hover-\(lane.rawValue)"
  }

  private var totalCount: Int {
    apiItems.count + inboxItems.count + decisions.count
  }

  private var isEmpty: Bool {
    apiItems.isEmpty && inboxItems.isEmpty && decisions.isEmpty
  }

  var body: some View {
    laneContent
      .taskBoardLaneColumnChrome(
        lane: lane,
        isCollapsed: isCollapsed,
        isDropCandidate: isDropCandidate,
        isDropTargeted: isDropTargeted
      )
      .dropDestination(
        for: TaskBoardCardDragPayload.self,
        isEnabled: isDropEnabled,
        action: handleDrop
      )
      .dropConfiguration(dropConfiguration)
      .onDropSessionUpdated(updateDropSession)
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("harness.task-board.column.\(lane.rawValue)")
  }

  @ViewBuilder private var laneContent: some View {
    if isCollapsed {
      TaskBoardCollapsedLane(
        lane: lane,
        count: totalCount,
        collapseOverridesRawValue: $collapseOverridesRawValue
      )
    } else {
      expandedLaneContent
    }
  }

  private var expandedLaneContent: some View {
    VStack(alignment: .leading, spacing: 0) {
      TaskBoardLaneHeader(
        lane: lane,
        count: totalCount,
        collapseOverridesRawValue: $collapseOverridesRawValue
      )

      Group {
        if isEmpty {
          TaskBoardEmptyLane(lane: lane)
            .padding(.horizontal, metrics.laneInnerPadding)
            .padding(.top, metrics.laneHeaderBodyTopPadding)
            .padding(.bottom, metrics.laneInnerPadding)
        } else {
          laneScrollSurface
        }
      }
      .taskBoardLaneBodyChrome(lane: lane, isDropTargeted: isDropTargeted)
    }
  }

  @ViewBuilder private var laneScrollSurface: some View {
    if perfScrollHookEnabled {
      ScrollView(.vertical, showsIndicators: true) {
        laneScrollContent
      }
      .scrollPosition($perfScrollPosition)
      .scrollBounceBehavior(.basedOnSize)
      .onReceive(
        NotificationCenter.default.publisher(
          for: HarnessMonitorPerfTaskBoardLaneScrollBus.scrollToBottom
        )
      ) { note in
        handlePerfLaneScroll(note: note, edge: "bottom")
      }
      .onReceive(
        NotificationCenter.default.publisher(
          for: HarnessMonitorPerfTaskBoardLaneScrollBus.scrollToTop
        )
      ) { note in
        handlePerfLaneScroll(note: note, edge: "top")
      }
    } else {
      ScrollView(.vertical, showsIndicators: true) {
        laneScrollContent
      }
      .scrollBounceBehavior(.basedOnSize)
    }
  }

  private var laneScrollContent: some View {
    laneRows
      .padding(.horizontal, metrics.laneInnerPadding)
      .padding(.top, metrics.laneHeaderBodyTopPadding)
      .padding(.bottom, metrics.laneInnerPadding)
      .frame(maxWidth: .infinity, alignment: .top)
  }

  private func handlePerfLaneScroll(note: Notification, edge: String) {
    guard
      let raw = note.userInfo?[HarnessMonitorPerfTaskBoardLaneScrollBus.laneRawKey] as? String,
      raw == lane.rawValue
    else { return }
    withAnimation(.easeOut(duration: 0.5)) {
      perfScrollPosition = ScrollPosition(edge: edge == "top" ? .top : .bottom)
    }
    HarnessMonitorPerfTaskBoardLaneScrollBus.recordAccepted(laneRaw: raw, edge: edge)
  }

  @ViewBuilder private var laneRows: some View {
    LazyVStack(spacing: metrics.laneSpacing) {
      if !decisions.isEmpty {
        decisionRows
      }
      ForEach(apiItems) { item in
        let cardID = TaskBoardCardID.api(item.id)
        let hoverID = TaskBoardLaneCardHoverID.api(item.id)
        TaskBoardItemRow(
          item: item,
          titleTypography: titleTypography,
          isHovered: hoveredCardID == hoverID,
          isSelected: selectionModel.selectedIDs.contains(cardID),
          selectionModel: selectionModel,
          actions: actions
        )
        .taskBoardCardFrame(id: hoverID, in: cardHoverCoordinateSpace)
        .contextMenu {
          TaskBoardCardContextMenu(cardID: cardID, actions: contextMenuActions)
        }
      }
      ForEach(inboxItems) { item in
        let cardID = TaskBoardCardID.inbox(
          sessionID: item.session.sessionId,
          taskID: item.task.taskId
        )
        let hoverID = TaskBoardLaneCardHoverID.inbox(
          sessionID: item.session.sessionId,
          taskID: item.task.taskId
        )
        TaskBoardInboxItemRow(
          item: item,
          titleTypography: titleTypography,
          isHovered: hoveredCardID == hoverID,
          isSelected: selectionModel.selectedIDs.contains(cardID),
          selectionModel: selectionModel,
          actions: actions
        )
        .taskBoardCardFrame(id: hoverID, in: cardHoverCoordinateSpace)
        .contextMenu {
          TaskBoardCardContextMenu(cardID: cardID, actions: contextMenuActions)
        }
      }
    }
    .frame(maxWidth: .infinity)
    .coordinateSpace(.named(cardHoverCoordinateSpace))
    .onContinuousHover(coordinateSpace: .named(cardHoverCoordinateSpace)) { phase in
      updateHoveredCard(phase: phase)
    }
    .onPreferenceChange(TaskBoardLaneCardFramePreferenceKey.self) { frames in
      guard hoverTracking.frames != frames else {
        return
      }
      hoverTracking.frames = frames
      updateHoveredCard(location: hoverTracking.location, frames: frames)
    }
  }

  @ViewBuilder private var decisionRows: some View {
    VStack(spacing: metrics.laneSpacing) {
      ForEach(decisions, id: \.id) { decision in
        let cardID = TaskBoardLaneCardHoverID.decision(decision.id)
        TaskBoardDecisionRow(
          decision: decision,
          fontScale: fontScale,
          isHovered: hoveredCardID == cardID,
          onOpenDecision: actions.openDecision
        )
        .taskBoardCardFrame(id: cardID, in: cardHoverCoordinateSpace)
      }
    }
  }

  private func updateHoveredCard(phase: HoverPhase) {
    switch phase {
    case .active(let location):
      hoverTracking.location = location
      updateHoveredCard(location: location, frames: hoverTracking.frames)
    case .ended:
      hoverTracking.location = nil
      updateHoveredCard(id: nil)
    }
  }

  private func updateHoveredCard(
    location: CGPoint?,
    frames: [TaskBoardLaneCardFrame]
  ) {
    guard let location else {
      updateHoveredCard(id: nil)
      return
    }
    updateHoveredCard(
      id: frames.first { $0.frame.contains(location) }?.id
    )
  }

  private func updateHoveredCard(id: TaskBoardLaneCardHoverID?) {
    guard hoveredCardID != id else {
      return
    }
    hoveredCardID = id
  }

  private func handleDrop(_ payloads: [TaskBoardCardDragPayload], session: DropSession) {
    guard
      isDropEnabled, isDropCandidate,
      let plan = TaskBoardCardDropPlan.resolve(payloads, to: lane)
    else {
      updateDropTargeted(false)
      return
    }
    _ = performDrop(
      signature: TaskBoardCardDropSignature(
        cardIDs: plan.items.map(\.id),
        destination: lane
      )
    ) {
      actions.moveCards(plan.items, to: lane)
    }
    updateDropTargeted(false)
  }

  private func dropConfiguration(for session: DropSession) -> DropConfiguration {
    let operation: DropOperation = isDropEnabled && isDropCandidate ? .move : .forbidden
    return DropConfiguration(operation: operation)
  }

  private func updateDropSession(_ session: DropSession) {
    switch session.phase {
    case .entering:
      dropDeduper.reset()
      updateDropTargeted(isDropEnabled && isDropCandidate)
    case .active:
      updateDropTargeted(isDropEnabled && isDropCandidate)
    case .exiting, .ended, .dataTransferCompleted:
      updateDropTargeted(false)
    @unknown default:
      updateDropTargeted(false)
    }
  }

  private func updateDropTargeted(_ targeted: Bool) {
    isDropTargeted = targeted
  }

  private func performDrop(
    signature: TaskBoardCardDropSignature,
    action: () -> Bool
  ) -> Bool {
    var deduper = dropDeduper
    let handled = deduper.perform(signature, move: action)
    dropDeduper = deduper
    return handled
  }
}
