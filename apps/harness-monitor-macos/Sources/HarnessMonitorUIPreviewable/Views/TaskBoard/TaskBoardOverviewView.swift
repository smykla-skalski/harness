import HarnessMonitorKit
import SwiftUI

public struct TaskBoardOverviewView: View {
  private let snapshot: TaskBoardInboxSnapshot
  private let taskBoardItems: [TaskBoardItem]
  private let onOpenItem: (TaskBoardInboxItem) -> Void
  private let onOpenTaskBoardItem: (TaskBoardItem) -> Void

  public init(
    snapshot: TaskBoardInboxSnapshot,
    taskBoardItems: [TaskBoardItem] = [],
    onOpenItem: @escaping (TaskBoardInboxItem) -> Void = { _ in },
    onOpenTaskBoardItem: @escaping (TaskBoardItem) -> Void = { _ in }
  ) {
    self.snapshot = snapshot
    self.taskBoardItems = Self.sortedTaskBoardItems(taskBoardItems)
    self.onOpenItem = onOpenItem
    self.onOpenTaskBoardItem = onOpenTaskBoardItem
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
      header
      if snapshot.isEmpty && taskBoardItems.isEmpty {
        emptyState
      } else {
        if !taskBoardItems.isEmpty {
          taskBoard
        }
        if !snapshot.isEmpty {
          sessionTaskBoard
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("harness.task-board.overview")
  }

  private var header: some View {
    HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.spacingMD) {
      Label("Task Board", systemImage: "rectangle.3.group")
        .scaledFont(.system(.title3, design: .rounded, weight: .semibold))
      Spacer(minLength: HarnessMonitorTheme.spacingMD)
      HStack(spacing: HarnessMonitorTheme.spacingSM) {
        countPill("\(taskBoardNeedsYouCount + snapshot.needsYouItemCount)", label: "Needs You")
        countPill("\(taskBoardItems.count + snapshot.items.count)", label: "Open")
        countPill("\(taskBoardReviewCount + snapshot.reviewItemCount)", label: "Review")
        countPill("\(taskBoardBlockedCount + snapshot.blockedItemCount)", label: "Blocked")
      }
    }
    .accessibilityAddTraits(.isHeader)
  }

  private var taskBoard: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Text("Board Items")
        .scaledFont(.subheadline.weight(.semibold))
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      ScrollView(.horizontal, showsIndicators: true) {
        HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingMD) {
          ForEach(taskBoardSections) { section in
            TaskBoardItemLaneColumn(
              section: section,
              onOpenItem: onOpenTaskBoardItem
            )
          }
        }
        .padding(.vertical, 2)
      }
      .scrollClipDisabled()
    }
  }

  private var sessionTaskBoard: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      if !taskBoardItems.isEmpty {
        Text("Session Tasks")
          .scaledFont(.subheadline.weight(.semibold))
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      }
      inboxBoard
    }
  }

  private var inboxBoard: some View {
    ScrollView(.horizontal, showsIndicators: true) {
      HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingMD) {
        ForEach(snapshot.sections) { section in
          TaskBoardInboxLaneColumn(
            section: section,
            onOpenItem: onOpenItem
          )
        }
      }
      .padding(.vertical, 2)
    }
    .scrollClipDisabled()
  }

  private var emptyState: some View {
    ContentUnavailableView("No Open Tasks", systemImage: "tray")
      .frame(maxWidth: .infinity, minHeight: 180)
      .background(
        .background.opacity(0.45), in: .rect(cornerRadius: HarnessMonitorTheme.cornerRadiusSM))
  }

  private func countPill(_ value: String, label: String) -> some View {
    HStack(spacing: 4) {
      Text(value)
        .scaledFont(.caption.weight(.bold))
      Text(label)
        .scaledFont(.caption)
    }
    .foregroundStyle(HarnessMonitorTheme.secondaryInk)
    .harnessPillPadding()
    .harnessControlPill(tint: HarnessMonitorTheme.secondaryInk)
  }

  private var taskBoardSections: [TaskBoardItemSection] {
    TaskBoardInboxLane.allCases.map { lane in
      TaskBoardItemSection(
        lane: lane,
        items: taskBoardItems.filter { TaskBoardInboxLane(status: $0.status) == lane }
      )
    }
  }

  private var taskBoardReviewCount: Int {
    taskBoardItems.count { TaskBoardInboxLane(status: $0.status) == .review }
  }

  private var taskBoardNeedsYouCount: Int {
    taskBoardItems.count { TaskBoardInboxLane(status: $0.status) == .needsYou }
  }

  private var taskBoardBlockedCount: Int {
    taskBoardItems.count { TaskBoardInboxLane(status: $0.status) == .blocked }
  }

  private static func sortedTaskBoardItems(_ items: [TaskBoardItem]) -> [TaskBoardItem] {
    items
      .filter { TaskBoardInboxLane(status: $0.status) != nil && $0.deletedAt == nil }
      .sorted { left, right in
        if left.priority != right.priority {
          return priorityRank(left.priority) > priorityRank(right.priority)
        }
        if left.updatedAt != right.updatedAt {
          return left.updatedAt > right.updatedAt
        }
        return left.id < right.id
      }
  }

  private static func priorityRank(_ priority: TaskBoardPriority) -> Int {
    switch priority {
    case .critical:
      3
    case .high:
      2
    case .medium:
      1
    case .low:
      0
    }
  }
}

private struct TaskBoardItemSection: Identifiable {
  let lane: TaskBoardInboxLane
  let items: [TaskBoardItem]

  var id: TaskBoardInboxLane { lane }
}

private struct TaskBoardItemLaneColumn: View {
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

private struct TaskBoardInboxLaneColumn: View {
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

private struct TaskBoardLaneHeader: View {
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

private struct TaskBoardEmptyLane: View {
  var body: some View {
    Text("Clear")
      .scaledFont(.caption.weight(.medium))
      .foregroundStyle(HarnessMonitorTheme.tertiaryInk)
      .frame(maxWidth: .infinity, minHeight: 72, alignment: .center)
  }
}

private struct TaskBoardItemRow: View {
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

private struct TaskBoardInboxItemRow: View {
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

private func priorityColor(for priority: TaskBoardPriority) -> Color {
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

private func taskBoardStatusColor(for status: TaskBoardStatus) -> Color {
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
