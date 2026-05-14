import HarnessMonitorKit
import SwiftUI

public struct TaskBoardOverviewView: View {
  private let snapshot: TaskBoardInboxSnapshot
  private let onOpenItem: (TaskBoardInboxItem) -> Void

  public init(
    snapshot: TaskBoardInboxSnapshot,
    onOpenItem: @escaping (TaskBoardInboxItem) -> Void = { _ in }
  ) {
    self.snapshot = snapshot
    self.onOpenItem = onOpenItem
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
      header
      if snapshot.isEmpty {
        emptyState
      } else {
        board
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
        countPill("\(snapshot.items.count)", label: "Inbox")
        countPill("\(snapshot.reviewItemCount)", label: "Review")
        countPill("\(snapshot.blockedItemCount)", label: "Blocked")
      }
    }
    .accessibilityAddTraits(.isHeader)
  }

  private var board: some View {
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
      .background(.regularMaterial, in: .rect(cornerRadius: HarnessMonitorTheme.cornerRadiusSM))
  }

  private func countPill(_ value: String, label: String) -> some View {
    HStack(spacing: 4) {
      Text(value)
        .scaledFont(.caption.weight(.bold))
      Text(label)
        .scaledFont(.caption)
    }
    .foregroundStyle(HarnessMonitorTheme.secondaryInk)
    .padding(.horizontal, HarnessMonitorTheme.pillPaddingH)
    .padding(.vertical, HarnessMonitorTheme.pillPaddingV)
    .background(.thinMaterial, in: .capsule)
  }
}

private struct TaskBoardInboxLaneColumn: View {
  let section: TaskBoardInboxSection
  let onOpenItem: (TaskBoardInboxItem) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      HStack(spacing: HarnessMonitorTheme.spacingSM) {
        Image(systemName: section.lane.systemImage)
          .foregroundStyle(laneColor)
          .frame(width: 16)
        Text(section.lane.title)
          .scaledFont(.subheadline.weight(.semibold))
        Spacer(minLength: HarnessMonitorTheme.spacingSM)
        Text("\(section.items.count)")
          .scaledFont(.caption.weight(.bold))
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      }
      .frame(height: 24)

      if section.items.isEmpty {
        emptyLane
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

  private var emptyLane: some View {
    Text("Clear")
      .scaledFont(.caption.weight(.medium))
      .foregroundStyle(HarnessMonitorTheme.tertiaryInk)
      .frame(maxWidth: .infinity, minHeight: 72, alignment: .center)
  }

  private var laneColor: Color {
    switch section.lane {
    case .blocked:
      HarnessMonitorTheme.danger
    case .review:
      HarnessMonitorTheme.caution
    case .active:
      HarnessMonitorTheme.warmAccent
    case .open:
      HarnessMonitorTheme.accent
    }
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
    .buttonStyle(.plain)
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
