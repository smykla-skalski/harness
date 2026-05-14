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

extension UTType {
  static let harnessMonitorTaskBoardItem = UTType(
    exportedAs: "io.harnessmonitor.task-board-item",
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
    .taskBoardLaneColumnChrome(lane: section.lane)
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
  @Environment(\.fontScale)
  private var fontScale

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
      .taskBoardLaneBodyChrome(lane: section.lane)
    }
    .taskBoardLaneColumnChrome(lane: section.lane)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("harness.task-board.column.\(section.lane.rawValue)")
  }
}

struct TaskBoardLaneHeader: View {
  let lane: TaskBoardInboxLane
  let count: Int
  @Environment(\.fontScale)
  private var fontScale

  private var metrics: TaskBoardLaneMetrics { TaskBoardLaneMetrics(fontScale: fontScale) }

  var body: some View {
    HStack(spacing: metrics.laneSpacing) {
      Image(systemName: lane.systemImage)
        .foregroundStyle(taskBoardLaneColor(for: lane))
        .frame(width: metrics.headerIconWidth)
      Text(lane.title)
        .scaledFont(.subheadline.weight(.semibold))
      Spacer(minLength: metrics.laneSpacing)
      Text("\(count)")
        .scaledFont(.caption.weight(.bold))
        .foregroundStyle(taskBoardLaneColor(for: lane))
        .monospacedDigit()
        .padding(.horizontal, metrics.countHorizontalPadding)
        .padding(.vertical, metrics.countVerticalPadding)
        .background(taskBoardLaneColor(for: lane).opacity(0.14), in: .capsule)
    }
    .padding(.horizontal, metrics.headerHorizontalPadding)
    .padding(.vertical, metrics.headerVerticalPadding)
    .background(taskBoardLaneColor(for: lane).opacity(0.10), in: .rect(cornerRadius: 6))
    .overlay(
      RoundedRectangle(cornerRadius: 6)
        .stroke(taskBoardLaneColor(for: lane).opacity(0.20), lineWidth: 1)
    )
  }
}

private struct TaskBoardLaneColumnChrome: ViewModifier {
  let lane: TaskBoardInboxLane
  @Environment(\.fontScale)
  private var fontScale

  private var metrics: TaskBoardLaneMetrics { TaskBoardLaneMetrics(fontScale: fontScale) }

  func body(content: Content) -> some View {
    content
      .padding(.horizontal, metrics.laneInnerPadding)
      .padding(.vertical, metrics.laneInnerPadding)
      .frame(width: metrics.laneWidth, alignment: .topLeading)
      .frame(minHeight: metrics.laneMinHeight, alignment: .topLeading)
      .background(.background.opacity(0.18), in: .rect(cornerRadius: 8))
      .overlay(alignment: .top) {
        Rectangle()
          .fill(taskBoardLaneColor(for: lane).opacity(0.70))
          .frame(height: 2)
          .clipShape(.rect(topLeadingRadius: 8, topTrailingRadius: 8))
      }
  }
}

extension View {
  func taskBoardLaneColumnChrome(lane: TaskBoardInboxLane) -> some View {
    modifier(TaskBoardLaneColumnChrome(lane: lane))
  }
}

private struct TaskBoardLaneBodyChrome: ViewModifier {
  let lane: TaskBoardInboxLane
  let isDropTargeted: Bool
  @Environment(\.fontScale)
  private var fontScale

  private var metrics: TaskBoardLaneMetrics { TaskBoardLaneMetrics(fontScale: fontScale) }

  func body(content: Content) -> some View {
    content
      .frame(maxWidth: .infinity, minHeight: metrics.laneBodyMinHeight, alignment: .top)
      .padding(.top, metrics.laneBodyTopPadding)
      .background(
        dropBackgroundColor,
        in: .rect(cornerRadius: 6)
      )
      .overlay {
        if isDropTargeted {
          RoundedRectangle(cornerRadius: 6)
            .stroke(taskBoardLaneColor(for: lane).opacity(0.38), lineWidth: 1)
        }
      }
  }

  private var dropBackgroundColor: Color {
    if isDropTargeted {
      return taskBoardLaneColor(for: lane).opacity(0.08)
    }
    return Color.clear
  }
}

extension View {
  func taskBoardLaneBodyChrome(
    lane: TaskBoardInboxLane,
    isDropTargeted: Bool = false
  ) -> some View {
    modifier(TaskBoardLaneBodyChrome(lane: lane, isDropTargeted: isDropTargeted))
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
          Circle()
            .fill(priorityColor(for: item.priority))
            .frame(width: metrics.cardMarkerSize, height: metrics.cardMarkerSize)
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
        HStack(spacing: metrics.laneBodyTopPadding) {
          taskPill(item.status.title, color: taskBoardStatusColor(for: item.status))
          taskPill(item.priority.title, color: priorityColor(for: item.priority))
          if let policyTraceCount = item.workflow?.policyTraceIds.count, policyTraceCount > 0 {
            taskPill("\(policyTraceCount) policy", color: HarnessMonitorTheme.secondaryInk)
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .frame(minHeight: metrics.cardMinHeight, alignment: .topLeading)
      .padding(metrics.cardPadding)
    }
    .harnessInteractiveCardButtonStyle(cornerRadius: 8)
    .background(.background.opacity(0.56), in: .rect(cornerRadius: 8))
    .overlay(alignment: .leading) {
      Rectangle()
        .fill(taskBoardStatusColor(for: item.status).opacity(0.82))
        .frame(width: metrics.cardAccentWidth)
        .clipShape(.rect(topLeadingRadius: 8, bottomLeadingRadius: 8))
    }
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .stroke(HarnessMonitorTheme.controlBorder.opacity(0.46), lineWidth: 1)
    )
    .draggable(dragPayload) {
      TaskBoardItemDragPreviewCard(item: item)
    }
    .accessibilityIdentifier("harness.task-board.api-item.\(item.id)")
  }

  private func taskPill(_ label: String, color: Color) -> some View {
    Text(label)
      .scaledFont(.caption2.weight(.bold))
      .foregroundStyle(color)
      .lineLimit(1)
      .padding(.horizontal, metrics.pillHorizontalPadding)
      .padding(.vertical, metrics.pillVerticalPadding)
      .background(color.opacity(0.16), in: .capsule)
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

  var body: some View {
    Button {
      onOpenItem(item)
    } label: {
      VStack(alignment: .leading, spacing: metrics.laneSpacing) {
        HStack(alignment: .top, spacing: metrics.laneSpacing) {
          Circle()
            .fill(severityColor(for: item.task.severity))
            .frame(width: metrics.cardMarkerSize, height: metrics.cardMarkerSize)
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
        HStack(spacing: metrics.laneBodyTopPadding) {
          taskPill(item.task.status.title, color: taskStatusColor(for: item.task.status))
          taskPill(item.task.severity.title, color: severityColor(for: item.task.severity))
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .frame(minHeight: metrics.cardMinHeight, alignment: .topLeading)
      .padding(metrics.cardPadding)
    }
    .harnessInteractiveCardButtonStyle(cornerRadius: 8)
    .background(.background.opacity(0.56), in: .rect(cornerRadius: 8))
    .overlay(alignment: .leading) {
      Rectangle()
        .fill(taskStatusColor(for: item.task.status).opacity(0.82))
        .frame(width: metrics.cardAccentWidth)
        .clipShape(.rect(topLeadingRadius: 8, bottomLeadingRadius: 8))
    }
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .stroke(HarnessMonitorTheme.controlBorder.opacity(0.46), lineWidth: 1)
    )
    .accessibilityIdentifier("harness.task-board.item.\(item.task.taskId)")
  }

  private func taskPill(_ label: String, color: Color) -> some View {
    Text(label)
      .scaledFont(.caption2.weight(.bold))
      .foregroundStyle(color)
      .lineLimit(1)
      .padding(.horizontal, metrics.pillHorizontalPadding)
      .padding(.vertical, metrics.pillVerticalPadding)
      .background(color.opacity(0.16), in: .capsule)
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
