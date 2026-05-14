import HarnessMonitorKit
import SwiftUI

struct TaskBoardItemLaneColumn: View {
  let section: TaskBoardItemSection
  let onOpenItem: (TaskBoardItem) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      TaskBoardLaneHeader(lane: section.lane, count: section.items.count)

      if section.items.isEmpty {
        TaskBoardEmptyLane()
      } else {
        VStack(spacing: HarnessMonitorTheme.spacingSM) {
          ForEach(section.items.prefix(5)) { item in
            TaskBoardItemRow(item: item, onOpenItem: onOpenItem)
          }
        }
      }
    }
    .frame(width: 260, alignment: .topLeading)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("harness.task-board.api-column.\(section.lane.rawValue)")
  }
}

struct TaskBoardInboxLaneColumn: View {
  let section: TaskBoardInboxSection
  let onOpenItem: (TaskBoardInboxItem) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      TaskBoardLaneHeader(lane: section.lane, count: section.items.count)

      if section.items.isEmpty {
        TaskBoardEmptyLane()
      } else {
        VStack(spacing: HarnessMonitorTheme.spacingSM) {
          ForEach(section.items.prefix(5)) { item in
            TaskBoardInboxItemRow(
              item: item,
              onOpenItem: onOpenItem
            )
          }
        }
      }
    }
    .frame(width: 260, alignment: .topLeading)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("harness.task-board.column.\(section.lane.rawValue)")
  }
}

struct TaskBoardLaneHeader: View {
  let lane: TaskBoardInboxLane
  let count: Int

  var body: some View {
    HStack(spacing: HarnessMonitorTheme.spacingSM) {
      Image(systemName: lane.systemImage)
        .foregroundStyle(laneColor)
        .frame(width: 16)
      Text(lane.title)
        .scaledFont(.subheadline.weight(.semibold))
      Spacer(minLength: HarnessMonitorTheme.spacingSM)
      Text("\(count)")
        .scaledFont(.caption.weight(.bold))
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
    }
    .frame(height: 24)
  }

  private var laneColor: Color {
    switch lane {
    case .needsYou:
      HarnessMonitorTheme.danger
    case .ready:
      HarnessMonitorTheme.accent
    case .blocked:
      HarnessMonitorTheme.danger
    case .review:
      HarnessMonitorTheme.caution
    case .running:
      HarnessMonitorTheme.warmAccent
    case .backlog:
      HarnessMonitorTheme.accent
    }
  }
}

struct TaskBoardEmptyLane: View {
  var body: some View {
    Text("Clear")
      .scaledFont(.caption.weight(.medium))
      .foregroundStyle(HarnessMonitorTheme.tertiaryInk)
      .frame(maxWidth: .infinity, minHeight: 72, alignment: .center)
  }
}

struct TaskBoardItemRow: View {
  let item: TaskBoardItem
  let onOpenItem: (TaskBoardItem) -> Void

  var body: some View {
    Button {
      onOpenItem(item)
    } label: {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
        HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingSM) {
          Circle()
            .fill(priorityColor(for: item.priority))
            .frame(width: 8, height: 8)
            .padding(.top, 6)
          VStack(alignment: .leading, spacing: 3) {
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
        HStack(spacing: HarnessMonitorTheme.spacingXS) {
          taskPill(item.status.title, color: taskBoardStatusColor(for: item.status))
          taskPill(item.priority.title, color: priorityColor(for: item.priority))
          if let policyTraceCount = item.workflow?.policyTraceIds.count, policyTraceCount > 0 {
            taskPill("\(policyTraceCount) policy", color: HarnessMonitorTheme.secondaryInk)
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(HarnessMonitorTheme.spacingSM)
    }
    .harnessInteractiveCardButtonStyle(cornerRadius: 8)
    .background(.background.opacity(0.45), in: .rect(cornerRadius: 8))
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .stroke(HarnessMonitorTheme.controlBorder.opacity(0.55), lineWidth: 1)
    )
    .accessibilityIdentifier("harness.task-board.api-item.\(item.id)")
  }

  private func taskPill(_ label: String, color: Color) -> some View {
    Text(label)
      .scaledFont(.caption2.weight(.bold))
      .foregroundStyle(color)
      .lineLimit(1)
      .padding(.horizontal, HarnessMonitorTheme.spacingSM)
      .padding(.vertical, 3)
      .background(color.opacity(0.12), in: .capsule)
  }
}

struct TaskBoardInboxItemRow: View {
  let item: TaskBoardInboxItem
  let onOpenItem: (TaskBoardInboxItem) -> Void

  var body: some View {
    Button {
      onOpenItem(item)
    } label: {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
        HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingSM) {
          Circle()
            .fill(severityColor(for: item.task.severity))
            .frame(width: 8, height: 8)
            .padding(.top, 6)
          VStack(alignment: .leading, spacing: 3) {
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
        HStack(spacing: HarnessMonitorTheme.spacingXS) {
          taskPill(item.task.status.title, color: taskStatusColor(for: item.task.status))
          taskPill(item.task.severity.title, color: severityColor(for: item.task.severity))
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(HarnessMonitorTheme.spacingSM)
    }
    .harnessInteractiveCardButtonStyle(cornerRadius: 8)
    .background(.background.opacity(0.45), in: .rect(cornerRadius: 8))
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .stroke(HarnessMonitorTheme.controlBorder.opacity(0.55), lineWidth: 1)
    )
    .accessibilityIdentifier("harness.task-board.item.\(item.task.taskId)")
  }

  private func taskPill(_ label: String, color: Color) -> some View {
    Text(label)
      .scaledFont(.caption2.weight(.bold))
      .foregroundStyle(color)
      .lineLimit(1)
      .padding(.horizontal, HarnessMonitorTheme.spacingSM)
      .padding(.vertical, 3)
      .background(color.opacity(0.12), in: .capsule)
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
