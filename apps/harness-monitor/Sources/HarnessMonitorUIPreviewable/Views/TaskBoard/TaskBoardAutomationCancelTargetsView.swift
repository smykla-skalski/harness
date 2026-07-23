import HarnessMonitorKit
import SwiftUI

struct TaskBoardAutomationCancelTargetsView: View {
  let targets: [TaskBoardAutomationCancelTargetPresentation]
  let isTruncated: Bool
  let blockedReason: String?
  let activeAction: TaskBoardAutomationInspectorAction?
  let onForceCancel: (TaskBoardAutomationCancelTarget) -> Void

  var body: some View {
    TaskBoardAutomationSubsectionHeader(title: "Remote executions")

    if let blockedReason, !targets.isEmpty {
      Label(blockedReason, systemImage: "lock.trianglebadge.exclamationmark")
        .font(.caption)
        .foregroundStyle(HarnessMonitorTheme.caution)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("harness.task-board.automation.forceCancel-blocked")
    }

    if targets.isEmpty {
      TaskBoardAutomationPlaceholder(
        title: "No exact remote workflows are eligible for force cancel",
        systemImage: "checkmark.shield"
      )
    } else {
      VStack(spacing: HarnessMonitorTheme.spacingSM) {
        ForEach(targets) { target in
          targetRow(target)
        }
      }
    }

    if isTruncated {
      Label(
        "Showing the first 100 eligible targets. Refresh after a cancellation to inspect later targets.",
        systemImage: "ellipsis.circle"
      )
      .font(.caption)
      .foregroundStyle(HarnessMonitorTheme.caution)
      .fixedSize(horizontal: false, vertical: true)
      .accessibilityIdentifier("harness.task-board.automation.forceCancel-truncated")
    }
  }

  private func targetRow(
    _ presentation: TaskBoardAutomationCancelTargetPresentation
  ) -> some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.spacingSM) {
        Text(presentation.title)
          .font(.caption.weight(.semibold))
          .foregroundStyle(.primary)
          .lineLimit(1)
          .truncationMode(.middle)
        Spacer(minLength: HarnessMonitorTheme.spacingSM)
        Text(presentation.state)
          .font(.caption2.weight(.medium))
          .foregroundStyle(
            presentation.target.cancelPending
              ? HarnessMonitorTheme.caution
              : HarnessMonitorTheme.secondaryInk
          )
      }

      targetDetail(presentation.execution)
      targetDetail(presentation.assignment)

      HStack(alignment: .center, spacing: HarnessMonitorTheme.spacingSM) {
        targetDetail(presentation.binding)
        Spacer(minLength: HarnessMonitorTheme.spacingSM)
        Button(role: .destructive) {
          onForceCancel(presentation.target)
        } label: {
          Label("Force Cancel", systemImage: "xmark.octagon.fill")
        }
        .harnessActionButtonStyle(variant: .bordered, tint: HarnessMonitorTheme.danger)
        .harnessNativeFormControl()
        .controlSize(HarnessMonitorControlMetrics.compactControlSize)
        .disabled(buttonBlockedReason(for: presentation.target) != nil)
        .help(
          buttonBlockedReason(for: presentation.target)
            ?? "Force-cancel this exact remote workflow binding"
        )
        .accessibilityIdentifier(
          "harness.task-board.automation.forceCancel.\(presentation.id)"
        )
        .accessibilityLabel(presentation.forceCancelAccessibilityLabel)
      }
    }
    .padding(HarnessMonitorTheme.spacingSM)
    .background(HarnessMonitorTheme.ink.opacity(0.04), in: .rect(cornerRadius: 8))
    .overlay {
      RoundedRectangle(cornerRadius: 8)
        .strokeBorder(HarnessMonitorTheme.ink.opacity(0.1))
    }
    .accessibilityElement(children: .contain)
  }

  private func targetDetail(_ value: String) -> some View {
    Text(value)
      .font(.caption2)
      .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      .lineLimit(1)
      .truncationMode(.middle)
      .textSelection(.enabled)
  }

  private func buttonBlockedReason(
    for target: TaskBoardAutomationCancelTarget
  ) -> String? {
    if target.cancelPending {
      return "Cancellation is already pending"
    }
    if activeAction != nil {
      return "Another automation action is in progress"
    }
    return blockedReason
  }
}
