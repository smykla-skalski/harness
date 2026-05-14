import HarnessMonitorKit
import SwiftUI
import UniformTypeIdentifiers

struct TaskBoardItemDragPayload: Codable, Transferable {
  let itemID: String
  let status: TaskBoardStatus

  static var transferRepresentation: some TransferRepresentation {
    CodableRepresentation(contentType: .harnessMonitorTaskBoardItem)
  }

  var sourceLane: TaskBoardInboxLane? {
    TaskBoardInboxLane(status: status)
  }
}

struct TaskBoardInboxItemDragPayload: Codable, Transferable {
  let sessionID: String
  let taskID: String
  let status: TaskStatus
  private let laneRawValue: String

  enum CodingKeys: String, CodingKey {
    case sessionID
    case taskID
    case status
    case laneRawValue
  }

  init(sessionID: String, taskID: String, status: TaskStatus, lane: TaskBoardInboxLane) {
    self.sessionID = sessionID
    self.taskID = taskID
    self.status = status
    laneRawValue = lane.rawValue
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    sessionID = try container.decode(String.self, forKey: .sessionID)
    taskID = try container.decode(String.self, forKey: .taskID)
    status = try container.decode(TaskStatus.self, forKey: .status)
    laneRawValue = try container.decode(String.self, forKey: .laneRawValue)
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(sessionID, forKey: .sessionID)
    try container.encode(taskID, forKey: .taskID)
    try container.encode(status, forKey: .status)
    try container.encode(laneRawValue, forKey: .laneRawValue)
  }

  static var transferRepresentation: some TransferRepresentation {
    CodableRepresentation(contentType: .harnessMonitorTaskBoardInboxItem)
  }

  var sourceLane: TaskBoardInboxLane? {
    TaskBoardInboxLane(rawValue: laneRawValue)
  }
}

extension UTType {
  static let harnessMonitorTaskBoardItem = UTType(
    exportedAs: "io.harnessmonitor.task-board-item",
    conformingTo: .json
  )

  static let harnessMonitorTaskBoardInboxItem = UTType(
    exportedAs: "io.harnessmonitor.task-board-inbox-item",
    conformingTo: .json
  )
}

struct TaskBoardItemLaneColumn: View {
  let section: TaskBoardItemSection
  let onOpenItem: (TaskBoardItem) -> Void
  let onMoveItem: (String, TaskBoardInboxLane) -> Bool
  @Environment(\.fontScale)
  private var fontScale
  @State private var isDropTargeted = false

  private var metrics: TaskBoardLaneMetrics { TaskBoardLaneMetrics(fontScale: fontScale) }

  var body: some View {
    VStack(alignment: .leading, spacing: metrics.laneSpacing) {
      TaskBoardLaneHeader(lane: section.lane, count: section.items.count)

      Group {
        if section.items.isEmpty {
          TaskBoardEmptyLane(lane: section.lane)
        } else {
          VStack(spacing: metrics.laneSpacing) {
            ForEach(section.items.prefix(5)) { item in
              TaskBoardItemRow(item: item, onOpenItem: onOpenItem)
            }
            TaskBoardLaneOverflowRow(hiddenCount: section.items.count - 5)
          }
        }
      }
      .taskBoardLaneBodyChrome(lane: section.lane, isDropTargeted: isDropTargeted)
    }
    .taskBoardLaneColumnChrome(lane: section.lane, isDropTargeted: isDropTargeted)
    .dropDestination(for: TaskBoardItemDragPayload.self, action: handleDrop) { targeted in
      isDropTargeted = targeted
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("harness.task-board.api-column.\(section.lane.rawValue)")
  }

  private func handleDrop(_ payloads: [TaskBoardItemDragPayload], _: CGPoint) -> Bool {
    TaskBoardLaneDropPolicy.moveFirstPayload(
      payloads,
      to: section.lane,
      move: onMoveItem
    )
  }
}

struct TaskBoardInboxLaneColumn: View {
  let section: TaskBoardInboxSection
  let onOpenItem: (TaskBoardInboxItem) -> Void
  let onMoveItem: (TaskBoardInboxItemDragPayload, TaskBoardInboxLane) -> Bool
  @Environment(\.fontScale)
  private var fontScale
  @State private var isDropTargeted = false

  private var metrics: TaskBoardLaneMetrics { TaskBoardLaneMetrics(fontScale: fontScale) }

  var body: some View {
    VStack(alignment: .leading, spacing: metrics.laneSpacing) {
      TaskBoardLaneHeader(lane: section.lane, count: section.items.count)

      Group {
        if section.items.isEmpty {
          TaskBoardEmptyLane(lane: section.lane)
        } else {
          VStack(spacing: metrics.laneSpacing) {
            ForEach(section.items.prefix(5)) { item in
              TaskBoardInboxItemRow(
                item: item,
                onOpenItem: onOpenItem
              )
            }
            TaskBoardLaneOverflowRow(hiddenCount: section.items.count - 5)
          }
        }
      }
      .taskBoardLaneBodyChrome(lane: section.lane, isDropTargeted: isDropTargeted)
    }
    .taskBoardLaneColumnChrome(lane: section.lane, isDropTargeted: isDropTargeted)
    .dropDestination(for: TaskBoardInboxItemDragPayload.self, action: handleDrop) { targeted in
      isDropTargeted = targeted
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("harness.task-board.column.\(section.lane.rawValue)")
  }

  private func handleDrop(_ payloads: [TaskBoardInboxItemDragPayload], _: CGPoint) -> Bool {
    TaskBoardInboxDropPolicy.moveFirstPayload(
      payloads,
      to: section.lane,
      move: onMoveItem
    )
  }
}

struct TaskBoardItemRow: View {
  let item: TaskBoardItem
  let onOpenItem: (TaskBoardItem) -> Void
  @Environment(\.fontScale)
  private var fontScale

  private var dragPayload: TaskBoardItemDragPayload {
    TaskBoardItemDragPayload(itemID: item.id, status: item.status)
  }

  private var metrics: TaskBoardLaneMetrics { TaskBoardLaneMetrics(fontScale: fontScale) }

  var body: some View {
    Button {
      onOpenItem(item)
    } label: {
      VStack(alignment: .leading, spacing: metrics.laneSpacing) {
        HStack(alignment: .top, spacing: metrics.laneSpacing) {
          TaskBoardCardLeadingIcon(systemImage: statusSymbol, tint: statusTint)
            .padding(.top, metrics.cardMarkerTopPadding)
          VStack(alignment: .leading, spacing: metrics.rowTextSpacing) {
            Text(item.title)
              .scaledFont(.subheadline.weight(.semibold))
              .foregroundStyle(HarnessMonitorTheme.ink)
              .lineLimit(2)
              .multilineTextAlignment(.leading)
            Text(item.projectId ?? item.agentMode.title)
              .scaledFont(.caption)
              .foregroundStyle(HarnessMonitorTheme.secondaryInk)
              .lineLimit(1)
              .truncationMode(.middle)
          }
          Spacer(minLength: 0)
        }
        ViewThatFits(in: .horizontal) {
          HStack(spacing: metrics.laneBodyTopPadding) {
            badgeContent
          }
          VStack(alignment: .leading, spacing: metrics.laneBodyTopPadding) {
            badgeContent
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .frame(minHeight: metrics.cardMinHeight, alignment: .topLeading)
      .padding(metrics.cardPadding)
    }
    .taskBoardCardChrome()
    .draggable(dragPayload) {
      TaskBoardItemDragPreviewCard(item: item)
    }
    .accessibilityIdentifier("harness.task-board.api-item.\(item.id)")
  }

  private var statusTint: Color {
    taskBoardStatusColor(for: item.status)
  }

  private var statusSymbol: String {
    TaskBoardInboxLane(status: item.status)?.systemImage ?? "tray"
  }

  @ViewBuilder private var badgeContent: some View {
    TaskBoardCardPill(label: item.status.title, tint: statusTint)
    TaskBoardCardPill(label: item.priority.title, tint: priorityColor(for: item.priority))
    if let policyTraceCount = item.workflow?.policyTraceIds.count, policyTraceCount > 0 {
      TaskBoardCardPill(label: "\(policyTraceCount) policy", tint: HarnessMonitorTheme.secondaryInk)
    }
  }
}

private struct TaskBoardItemDragPreviewCard: View {
  let item: TaskBoardItem
  @Environment(\.fontScale)
  private var fontScale

  private var metrics: TaskBoardLaneMetrics { TaskBoardLaneMetrics(fontScale: fontScale) }

  var body: some View {
    VStack(alignment: .leading, spacing: metrics.laneBodyTopPadding) {
      Text(item.title)
        .scaledFont(.subheadline.weight(.semibold))
        .lineLimit(2)
      Text(item.status.title)
        .scaledFont(.caption.weight(.semibold))
        .foregroundStyle(taskBoardStatusColor(for: item.status))
    }
    .frame(width: metrics.dragPreviewWidth, alignment: .leading)
    .padding(metrics.cardPadding)
    .background(.background.opacity(0.92), in: .rect(cornerRadius: 8))
  }
}

struct TaskBoardInboxItemRow: View {
  let item: TaskBoardInboxItem
  let onOpenItem: (TaskBoardInboxItem) -> Void
  @Environment(\.fontScale)
  private var fontScale

  private var metrics: TaskBoardLaneMetrics { TaskBoardLaneMetrics(fontScale: fontScale) }

  private var dragPayload: TaskBoardInboxItemDragPayload {
    TaskBoardInboxItemDragPayload(
      sessionID: item.session.sessionId,
      taskID: item.task.taskId,
      status: item.task.status,
      lane: item.lane
    )
  }

  var body: some View {
    Button {
      onOpenItem(item)
    } label: {
      VStack(alignment: .leading, spacing: metrics.laneSpacing) {
        HStack(alignment: .top, spacing: metrics.laneSpacing) {
          TaskBoardCardLeadingIcon(systemImage: statusSymbol, tint: statusTint)
            .padding(.top, metrics.cardMarkerTopPadding)
          VStack(alignment: .leading, spacing: metrics.rowTextSpacing) {
            Text(item.task.title)
              .scaledFont(.subheadline.weight(.semibold))
              .foregroundStyle(HarnessMonitorTheme.ink)
              .lineLimit(2)
              .multilineTextAlignment(.leading)
            Text(item.subtitle)
              .scaledFont(.caption)
              .foregroundStyle(HarnessMonitorTheme.secondaryInk)
              .lineLimit(1)
              .truncationMode(.middle)
          }
          Spacer(minLength: 0)
        }
        ViewThatFits(in: .horizontal) {
          HStack(spacing: metrics.laneBodyTopPadding) {
            badgeContent
          }
          VStack(alignment: .leading, spacing: metrics.laneBodyTopPadding) {
            badgeContent
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .frame(minHeight: metrics.cardMinHeight, alignment: .topLeading)
      .padding(metrics.cardPadding)
    }
    .taskBoardCardChrome()
    .draggable(dragPayload) {
      TaskBoardInboxItemDragPreviewCard(item: item)
    }
    .accessibilityIdentifier("harness.task-board.item.\(item.task.taskId)")
  }

  private var statusTint: Color {
    taskStatusColor(for: item.task.status)
  }

  private var statusSymbol: String {
    item.lane.systemImage
  }

  @ViewBuilder private var badgeContent: some View {
    TaskBoardCardPill(label: item.task.status.title, tint: statusTint)
    TaskBoardCardPill(label: item.task.severity.title, tint: severityColor(for: item.task.severity))
  }
}

private struct TaskBoardInboxItemDragPreviewCard: View {
  let item: TaskBoardInboxItem
  @Environment(\.fontScale)
  private var fontScale

  private var metrics: TaskBoardLaneMetrics { TaskBoardLaneMetrics(fontScale: fontScale) }

  var body: some View {
    VStack(alignment: .leading, spacing: metrics.laneBodyTopPadding) {
      Text(item.task.title)
        .scaledFont(.subheadline.weight(.semibold))
        .lineLimit(2)
      Text(item.task.status.title)
        .scaledFont(.caption.weight(.semibold))
        .foregroundStyle(taskStatusColor(for: item.task.status))
    }
    .frame(width: metrics.dragPreviewWidth, alignment: .leading)
    .padding(metrics.cardPadding)
    .background(.background.opacity(0.92), in: .rect(cornerRadius: 8))
  }
}

func priorityColor(for priority: TaskBoardPriority) -> Color {
  switch priority {
  case .critical:
    HarnessMonitorTheme.danger
  case .high:
    HarnessMonitorTheme.caution
  case .medium:
    HarnessMonitorTheme.accent
  case .low:
    HarnessMonitorTheme.secondaryInk
  }
}

func taskBoardStatusColor(for status: TaskBoardStatus) -> Color {
  switch status {
  case .blocked:
    HarnessMonitorTheme.danger
  case .planReview, .inReview:
    HarnessMonitorTheme.caution
  case .planning, .inProgress:
    HarnessMonitorTheme.warmAccent
  case .new, .todo:
    HarnessMonitorTheme.accent
  case .done:
    HarnessMonitorTheme.secondaryInk
  }
}
