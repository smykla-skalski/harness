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
  let selectedCardIDs: Set<TaskBoardCardID>
  let onOpenAPIItem: (TaskBoardItem) -> Void
  let onOpenInboxItem: (TaskBoardInboxItem) -> Void
  let onOpenDecision: (Decision) -> Void
  let onToggleCollapse: () -> Void
  let onSelectCard: (TaskBoardCardID, [TaskBoardCardID], EventModifiers) -> Void
  let onMoveCards: ([TaskBoardCardDragItem], TaskBoardInboxLane) -> Bool
  @Environment(\.fontScale)
  private var fontScale
  @State private var isDropTargeted = false
  @State private var dropDeduper = TaskBoardDropDeduper<TaskBoardCardDropSignature>()
  @State private var perfScrollPosition = ScrollPosition()
  @State private var cardHoverLocation: CGPoint?
  @State private var cardHoverFrames: [TaskBoardLaneCardFrame] = []
  @State private var hoveredCardID: TaskBoardLaneCardHoverID?
  private let perfScrollHookEnabled = HarnessMonitorPerfTaskBoardLaneScrollBus.isActive()

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

  private var orderedCardIDs: [TaskBoardCardID] {
    apiItems.map { .api($0.id) }
      + inboxItems.map {
        .inbox(sessionID: $0.session.sessionId, taskID: $0.task.taskId)
      }
  }

  var body: some View {
    laneContent
      .taskBoardLaneColumnChrome(
        lane: lane,
        isCollapsed: isCollapsed,
        isDropTargeted: isDropTargeted
      )
      .dropDestination(for: TaskBoardCardDragPayload.self, action: handleDrop) { targeted in
        updateDropTargeted(targeted)
      }
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("harness.task-board.column.\(lane.rawValue)")
  }

  @ViewBuilder private var laneContent: some View {
    if isCollapsed {
      TaskBoardCollapsedLane(
        lane: lane,
        count: totalCount,
        onExpand: onToggleCollapse
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
        onToggleCollapse: onToggleCollapse
      )

      Group {
        if isEmpty {
          TaskBoardEmptyLane(lane: lane)
        } else {
          laneScrollSurface
        }
      }
      .taskBoardLaneBodyChrome(lane: lane, isDropTargeted: isDropTargeted)
      .padding(.horizontal, metrics.laneInnerPadding)
      .padding(.bottom, metrics.laneInnerPadding)
    }
  }

  @ViewBuilder private var laneScrollSurface: some View {
    if perfScrollHookEnabled {
      ScrollView(.vertical, showsIndicators: true) {
        laneRows
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
        laneRows
      }
      .scrollBounceBehavior(.basedOnSize)
    }
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
    VStack(spacing: metrics.laneSpacing) {
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
          isSelected: selectedCardIDs.contains(cardID),
          onSelect: { modifiers in
            onSelectCard(cardID, orderedCardIDs, modifiers)
          },
          onOpenItem: onOpenAPIItem
        )
        .taskBoardCardFrame(id: hoverID, in: cardHoverCoordinateSpace)
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
          isSelected: selectedCardIDs.contains(cardID),
          onSelect: { modifiers in
            onSelectCard(cardID, orderedCardIDs, modifiers)
          },
          onOpenItem: onOpenInboxItem
        )
        .taskBoardCardFrame(id: hoverID, in: cardHoverCoordinateSpace)
      }
    }
    .frame(maxWidth: .infinity)
    .coordinateSpace(.named(cardHoverCoordinateSpace))
    .onContinuousHover(coordinateSpace: .named(cardHoverCoordinateSpace)) { phase in
      updateHoveredCard(phase: phase)
    }
    .onPreferenceChange(TaskBoardLaneCardFramePreferenceKey.self) { frames in
      guard cardHoverFrames != frames else {
        return
      }
      cardHoverFrames = frames
      updateHoveredCard(location: cardHoverLocation, frames: frames)
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
          onOpenDecision: onOpenDecision
        )
        .taskBoardCardFrame(id: cardID, in: cardHoverCoordinateSpace)
      }
    }
  }

  private func updateHoveredCard(phase: HoverPhase) {
    switch phase {
    case .active(let location):
      cardHoverLocation = location
      updateHoveredCard(location: location, frames: cardHoverFrames)
    case .ended:
      cardHoverLocation = nil
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

  private func handleDrop(_ payloads: [TaskBoardCardDragPayload], _: CGPoint) -> Bool {
    guard let plan = TaskBoardCardDropPlan.resolve(payloads, to: lane) else {
      return false
    }
    return performDrop(
      signature: TaskBoardCardDropSignature(
        cardIDs: plan.items.map(\.id),
        destination: lane
      )
    ) {
      onMoveCards(plan.items, lane)
    }
  }

  private func updateDropTargeted(_ targeted: Bool) {
    isDropTargeted = targeted
    if !targeted {
      dropDeduper = TaskBoardDropDeduper()
    }
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

private struct TaskBoardCollapsedLane: View {
  let lane: TaskBoardInboxLane
  let count: Int
  let onExpand: () -> Void
  @Environment(\.fontScale)
  private var fontScale

  private var metrics: TaskBoardLaneMetrics { TaskBoardLaneMetrics(fontScale: fontScale) }
  private var countFont: Font {
    HarnessMonitorTextSize.scaledFont(.caption.weight(.bold), by: fontScale)
  }
  private var titleFont: Font {
    HarnessMonitorTextSize.scaledFont(.title3.weight(.semibold), by: fontScale)
  }
  private var collapsedButtonWidth: CGFloat {
    metrics.laneCollapsedWidth
  }
  private var collapsedContentWidth: CGFloat {
    max(0, metrics.laneCollapsedWidth - (2 * metrics.laneCollapsedInnerPadding))
  }
  private var collapsedButtonTopPadding: CGFloat {
    metrics.laneCollapsedInnerPadding + metrics.laneCollapsedContentTopPadding
  }

  var body: some View {
    Button(action: onExpand) {
      VStack(spacing: metrics.laneCollapsedContentTopPadding) {
        Text("\(count)")
          .font(countFont)
          .foregroundStyle(HarnessMonitorTheme.ink)
          .monospacedDigit()
          .frame(
            width: metrics.laneCollapsedBadgeSize,
            height: metrics.laneCollapsedBadgeSize
          )
          .background(HarnessMonitorTheme.controlBorder.opacity(0.34), in: Circle())
          .accessibilityHidden(true)

        collapsedTitle

        Spacer(minLength: 0)
      }
      .frame(
        minWidth: collapsedContentWidth,
        idealWidth: collapsedContentWidth,
        maxWidth: collapsedContentWidth,
        maxHeight: .infinity,
        alignment: .top
      )
      .padding(.horizontal, metrics.laneCollapsedInnerPadding)
      .padding(.top, collapsedButtonTopPadding)
      .padding(.bottom, metrics.laneCollapsedInnerPadding)
      .frame(
        minWidth: collapsedButtonWidth,
        idealWidth: collapsedButtonWidth,
        maxWidth: collapsedButtonWidth,
        maxHeight: .infinity,
        alignment: .top
      )
      .contentShape(Rectangle())
      .clipped()
    }
    .harnessPlainButtonStyle()
    .taskBoardLaneToggleFeedback(lane: lane, cornerRadius: metrics.cardCornerRadius)
    .help("Expand \(lane.title) board")
    .accessibilityLabel("Expand \(lane.title) board")
    .accessibilityValue("\(count) items")
  }

  private var collapsedTitle: some View {
    Text(lane.title)
      .font(titleFont)
      .foregroundStyle(HarnessMonitorTheme.ink.opacity(0.82))
      .lineLimit(1)
      .fixedSize(horizontal: true, vertical: false)
      .frame(
        width: metrics.laneCollapsedTitleHeight,
        height: metrics.laneCollapsedTextWidth,
        alignment: .leading
      )
      .rotationEffect(.degrees(90))
      .offset(y: collapsedTitleVerticalOffset)
      .frame(
        minWidth: collapsedContentWidth,
        idealWidth: collapsedContentWidth,
        maxWidth: collapsedContentWidth,
        minHeight: metrics.laneCollapsedTitleHeight,
        idealHeight: metrics.laneCollapsedTitleHeight,
        maxHeight: metrics.laneCollapsedTitleHeight,
        alignment: .top
      )
      .clipped()
  }

  private var collapsedTitleVerticalOffset: CGFloat {
    max(0, (metrics.laneCollapsedTitleHeight - metrics.laneCollapsedTextWidth) / 2)
  }
}
