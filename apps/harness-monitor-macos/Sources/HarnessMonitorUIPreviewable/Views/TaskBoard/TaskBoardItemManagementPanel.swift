import HarnessMonitorKit
import SwiftUI

struct TaskBoardItemManagementPanel: View {
  let item: TaskBoardItem
  let metrics: TaskBoardOverviewMetrics
  let isActionInFlight: Bool
  let onRunOnce: ((TaskBoardItem) -> Void)?
  let onEvaluate: ((TaskBoardItem) -> Void)?
  let onRefresh: (() -> Void)?
  let onClose: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: metrics.managementPanelSpacing) {
      HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.spacingSM) {
        Label("Manage Board Item", systemImage: "slider.horizontal.3")
          .scaledFont(.subheadline.weight(.semibold))
        Spacer(minLength: HarnessMonitorTheme.spacingSM)
        Button(action: onClose) {
          Image(systemName: "xmark")
            .accessibilityHidden(true)
        }
        .buttonStyle(.borderless)
        .frame(minWidth: metrics.iconControlMinWidth, minHeight: metrics.controlMinHeight)
        .help("Close board item")
        .accessibilityLabel("Close item panel")
      }

      Text(item.title)
        .scaledFont(.body.weight(.semibold))
        .lineLimit(2)
        .textSelection(.enabled)

      if !item.body.isEmpty {
        Text(item.body)
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .lineLimit(3)
          .textSelection(.enabled)
      }

      HStack(spacing: HarnessMonitorTheme.spacingXS) {
        managementPill(item.status.title, tint: taskBoardStatusColor(for: item.status))
        managementPill(item.priority.title, tint: priorityColor(for: item.priority))
        managementPill(item.hasLinkedSessionTask ? "Session Task" : "Board Only", tint: linkTint)
      }

      ViewThatFits(in: .horizontal) {
        HStack(spacing: HarnessMonitorTheme.spacingSM) {
          actionButtons
        }
        VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
          actionButtons
        }
      }
    }
    .padding(HarnessMonitorTheme.spacingMD)
    .frame(maxWidth: .infinity, minHeight: metrics.managementPanelMinHeight, alignment: .leading)
    .background(.background.opacity(0.56), in: .rect(cornerRadius: 8))
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .stroke(HarnessMonitorTheme.controlBorder.opacity(0.62), lineWidth: 1)
    )
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("harness.task-board.manage-item.\(item.id)")
  }

  @ViewBuilder private var actionButtons: some View {
    Button {
      onRunOnce?(item)
    } label: {
      Label("Run Once", systemImage: "play.circle")
        .scaledFont(.caption.weight(.semibold))
    }
    .frame(minHeight: metrics.controlMinHeight)
    .harnessActionButtonStyle(variant: .bordered, tint: HarnessMonitorTheme.accent)
    .controlSize(HarnessMonitorControlMetrics.compactControlSize)
    .disabled(isActionInFlight || onRunOnce == nil)

    Button {
      onEvaluate?(item)
    } label: {
      Label("Evaluate Item", systemImage: "checkmark.seal")
        .scaledFont(.caption.weight(.semibold))
    }
    .frame(minHeight: metrics.controlMinHeight)
    .harnessActionButtonStyle(variant: .bordered, tint: HarnessMonitorTheme.accent)
    .controlSize(HarnessMonitorControlMetrics.compactControlSize)
    .disabled(isActionInFlight || onEvaluate == nil)
    .help("Evaluate this board item")

    Button {
      onRefresh?()
    } label: {
      Label("Refresh", systemImage: "arrow.clockwise")
        .scaledFont(.caption.weight(.semibold))
    }
    .frame(minHeight: metrics.controlMinHeight)
    .harnessActionButtonStyle(variant: .bordered, tint: .secondary)
    .controlSize(HarnessMonitorControlMetrics.compactControlSize)
    .disabled(isActionInFlight || onRefresh == nil)
    .help("Refresh task board")
    .accessibilityIdentifier("harness.task-board.manage-item.refresh")
  }

  private var linkTint: Color {
    item.hasLinkedSessionTask ? HarnessMonitorTheme.accent : HarnessMonitorTheme.caution
  }

  private func managementPill(_ label: String, tint: Color) -> some View {
    Text(label)
      .scaledFont(.caption2.weight(.bold))
      .foregroundStyle(tint)
      .lineLimit(1)
      .padding(.horizontal, HarnessMonitorTheme.spacingSM)
      .padding(.vertical, 3)
      .background(tint.opacity(0.12), in: .capsule)
  }
}
