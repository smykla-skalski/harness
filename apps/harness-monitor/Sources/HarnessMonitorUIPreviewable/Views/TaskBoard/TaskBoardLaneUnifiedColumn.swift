import Foundation
import HarnessMonitorKit
import SwiftUI
import UniformTypeIdentifiers

struct TaskBoardLaneUnifiedColumn: View {
  let lane: TaskBoardInboxLane
  let apiItems: [TaskBoardItem]
  let inboxItems: [TaskBoardInboxItem]
  let decisions: [Decision]
  let isCollapsed: Bool
  let onOpenAPIItem: (TaskBoardItem) -> Void
  let onOpenInboxItem: (TaskBoardInboxItem) -> Void
  let onOpenDecision: (Decision) -> Void
  let onToggleCollapse: () -> Void
  let onMoveAPIItem: (String, TaskBoardInboxLane) -> Bool
  let onMoveInboxItem: (TaskBoardInboxItemDragPayload, TaskBoardInboxLane) -> Bool
  @Environment(\.fontScale)
  private var fontScale
  @State private var isAPIDropTargeted = false
  @State private var isInboxDropTargeted = false
  @State private var apiDropDeduper = TaskBoardDropDeduper<TaskBoardItemDropSignature>()
  @State private var inboxDropDeduper = TaskBoardDropDeduper<TaskBoardInboxItemDropSignature>()
  @State private var perfScrollPosition = ScrollPosition()
  private let perfScrollHookEnabled = HarnessMonitorPerfTaskBoardLaneScrollBus.isActive()

  private var metrics: TaskBoardLaneMetrics { TaskBoardLaneMetrics(fontScale: fontScale) }

  private var totalCount: Int {
    apiItems.count + inboxItems.count + decisions.count
  }

  private var isDropTargeted: Bool {
    isAPIDropTargeted || isInboxDropTargeted
  }

  private var isEmpty: Bool {
    apiItems.isEmpty && inboxItems.isEmpty && decisions.isEmpty
  }

  var body: some View {
    laneContent
      .taskBoardLaneColumnChrome(
        lane: lane,
        isCollapsed: isCollapsed,
        isDropTargeted: isDropTargeted
      )
      .dropDestination(for: TaskBoardItemDragPayload.self, action: handleAPIDrop) { targeted in
        updateAPIDropTargeted(targeted)
      }
      .onDrop(
        of: [.harnessMonitorTaskBoardItem],
        isTargeted: nil,
        perform: handleLegacyAPIDrop
      )
      .dropDestination(
        for: TaskBoardInboxItemDragPayload.self,
        action: handleInboxDrop
      ) { targeted in
        updateInboxDropTargeted(targeted)
      }
      .onDrop(
        of: [.harnessMonitorTaskBoardInboxItem],
        isTargeted: nil,
        perform: handleLegacyInboxDrop
      )
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
    VStack(alignment: .leading, spacing: metrics.laneSpacing) {
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
        TaskBoardItemRow(item: item, onOpenItem: onOpenAPIItem)
      }
      ForEach(inboxItems) { item in
        TaskBoardInboxItemRow(item: item, onOpenItem: onOpenInboxItem)
      }
    }
    .frame(maxWidth: .infinity)
  }

  @ViewBuilder private var decisionRows: some View {
    VStack(spacing: metrics.laneSpacing) {
      ForEach(decisions, id: \.id) { decision in
        TaskBoardDecisionRow(
          decision: decision,
          fontScale: fontScale,
          onOpenDecision: onOpenDecision
        )
      }
    }
  }

  private func handleAPIDrop(_ payloads: [TaskBoardItemDragPayload], _: CGPoint) -> Bool {
    guard let payload = payloads.first else {
      return false
    }
    return performAPIDrop(
      signature: TaskBoardItemDropSignature(itemID: payload.itemID, destination: lane)
    ) {
      TaskBoardLaneDropPolicy.moveFirstPayload(
        payloads,
        to: lane,
        move: onMoveAPIItem
      )
    }
  }

  private func handleInboxDrop(_ payloads: [TaskBoardInboxItemDragPayload], _: CGPoint) -> Bool {
    guard let payload = payloads.first else {
      return false
    }
    return performInboxDrop(
      signature: TaskBoardInboxItemDropSignature(
        sessionID: payload.sessionID,
        taskID: payload.taskID,
        destination: lane
      )
    ) {
      TaskBoardInboxDropPolicy.moveFirstPayload(
        payloads,
        to: lane,
        move: onMoveInboxItem
      )
    }
  }

  private func handleLegacyAPIDrop(_ providers: [NSItemProvider]) -> Bool {
    TaskBoardItemDragPayload.loadFirst(from: providers) { payload in
      _ = handleAPIDrop([payload], .zero)
    }
  }

  private func handleLegacyInboxDrop(_ providers: [NSItemProvider]) -> Bool {
    TaskBoardInboxItemDragPayload.loadFirst(from: providers) { payload in
      _ = handleInboxDrop([payload], .zero)
    }
  }

  private func updateAPIDropTargeted(_ targeted: Bool) {
    isAPIDropTargeted = targeted
    if !targeted {
      apiDropDeduper = TaskBoardDropDeduper()
    }
  }

  private func updateInboxDropTargeted(_ targeted: Bool) {
    isInboxDropTargeted = targeted
    if !targeted {
      inboxDropDeduper = TaskBoardDropDeduper()
    }
  }

  private func performAPIDrop(
    signature: TaskBoardItemDropSignature,
    action: () -> Bool
  ) -> Bool {
    var deduper = apiDropDeduper
    let handled = deduper.perform(signature, move: action)
    apiDropDeduper = deduper
    return handled
  }

  private func performInboxDrop(
    signature: TaskBoardInboxItemDropSignature,
    action: () -> Bool
  ) -> Bool {
    var deduper = inboxDropDeduper
    let handled = deduper.perform(signature, move: action)
    inboxDropDeduper = deduper
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
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      .padding(.top, metrics.laneCollapsedContentTopPadding)
      .contentShape(Rectangle())
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
      .minimumScaleFactor(0.72)
      .frame(width: metrics.laneCollapsedTitleHeight, alignment: .leading)
      .rotationEffect(.degrees(90), anchor: .topLeading)
      .offset(x: metrics.laneCollapsedTextWidth)
      .frame(
        width: metrics.laneCollapsedTextWidth,
        height: metrics.laneCollapsedTitleHeight,
        alignment: .top
      )
  }
}
