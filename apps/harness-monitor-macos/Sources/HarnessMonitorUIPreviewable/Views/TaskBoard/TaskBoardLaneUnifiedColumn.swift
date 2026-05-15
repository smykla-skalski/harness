import Foundation
import HarnessMonitorKit
import SwiftUI
import UniformTypeIdentifiers

struct TaskBoardLaneUnifiedColumn: View {
  let lane: TaskBoardInboxLane
  let apiItems: [TaskBoardItem]
  let inboxItems: [TaskBoardInboxItem]
  let decisions: [Decision]
  let onOpenAPIItem: (TaskBoardItem) -> Void
  let onOpenInboxItem: (TaskBoardInboxItem) -> Void
  let onOpenDecision: (Decision) -> Void
  let onMoveAPIItem: (String, TaskBoardInboxLane) -> Bool
  let onMoveInboxItem: (TaskBoardInboxItemDragPayload, TaskBoardInboxLane) -> Bool
  @Environment(\.fontScale)
  private var fontScale
  @State private var isAPIDropTargeted = false
  @State private var isInboxDropTargeted = false
  @State private var apiDropDeduper = TaskBoardDropDeduper<TaskBoardItemDropSignature>()
  @State private var inboxDropDeduper = TaskBoardDropDeduper<TaskBoardInboxItemDropSignature>()

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
    VStack(alignment: .leading, spacing: metrics.laneSpacing) {
      TaskBoardLaneHeader(lane: lane, count: totalCount)

      Group {
        if isEmpty {
          TaskBoardEmptyLane(lane: lane)
        } else {
          ScrollView(.vertical, showsIndicators: true) {
            VStack(spacing: metrics.laneSpacing) {
              ForEach(decisions, id: \.id) { decision in
                TaskBoardDecisionRow(decision: decision, onOpenDecision: onOpenDecision)
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
          .scrollBounceBehavior(.basedOnSize)
        }
      }
      .taskBoardLaneBodyChrome(lane: lane, isDropTargeted: isDropTargeted)
    }
    .taskBoardLaneColumnChrome(lane: lane, isDropTargeted: isDropTargeted)
    .dropDestination(for: TaskBoardItemDragPayload.self, action: handleAPIDrop) { targeted in
      updateAPIDropTargeted(targeted)
    }
    .onDrop(
      of: [.harnessMonitorTaskBoardItem],
      isTargeted: nil,
      perform: handleLegacyAPIDrop
    )
    .dropDestination(for: TaskBoardInboxItemDragPayload.self, action: handleInboxDrop) { targeted in
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
