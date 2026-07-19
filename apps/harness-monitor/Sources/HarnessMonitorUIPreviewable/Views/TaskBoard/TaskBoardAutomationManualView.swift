import SwiftUI

struct TaskBoardAutomationManualView: View {
  let presentation: TaskBoardAutomationPresentation
  let metrics: TaskBoardOverviewMetrics
  let isPresentationCurrent: Bool
  let activeAction: TaskBoardAutomationInspectorAction?
  let onStart: () -> Void
  let onStop: () -> Void
  let onRunOnce: () -> Void

  var body: some View {
    TaskBoardOperationsCard(title: "Manual controls", metrics: metrics) {
      if presentation.statePills.isEmpty {
        TaskBoardAutomationPlaceholder(
          title: "Waiting for automation status before enabling controls",
          systemImage: "lock.shield"
        )
      } else {
        TaskBoardAutomationPillFlow(pills: presentation.statePills)
      }

      if let controlBlockedReason {
        Label(controlBlockedReason, systemImage: "lock.trianglebadge.exclamationmark")
          .font(.caption)
          .foregroundStyle(HarnessMonitorTheme.caution)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.vertical, HarnessMonitorTheme.spacingMD)
          .accessibilityIdentifier("harness.task-board.automation.control-blocked")
      }

      TaskBoardAutomationSubsectionHeader(title: "Lifecycle")
      HarnessMonitorWrapLayout(
        spacing: HarnessMonitorTheme.spacingSM,
        lineSpacing: HarnessMonitorTheme.spacingSM
      ) {
        controlButton(
          action: .start,
          descriptor: TaskBoardActionButtonDescriptor(
            title: "Start",
            systemImage: "play.circle.fill",
            tint: HarnessMonitorTheme.accent,
            prominent: true,
            accessibilityIdentifier: "harness.task-board.automation.start",
            help: "Start continuous task-board automation"
          ),
          blockedReason: controlBlockedReason,
          perform: onStart
        )
        controlButton(
          action: .stop,
          descriptor: TaskBoardActionButtonDescriptor(
            title: "Stop",
            systemImage: "stop.circle",
            tint: HarnessMonitorTheme.danger,
            prominent: false,
            accessibilityIdentifier: "harness.task-board.automation.stop",
            help: "Stop task-board automation after current work drains"
          ),
          blockedReason: controlBlockedReason,
          perform: onStop
        )
        controlButton(
          action: .runOnce,
          descriptor: TaskBoardActionButtonDescriptor(
            title: "Run Once",
            systemImage: "playpause.circle",
            tint: HarnessMonitorTheme.accent,
            prominent: false,
            accessibilityIdentifier: "harness.task-board.automation.runOnce",
            help: "Run one task-board automation reconciliation"
          ),
          blockedReason: controlBlockedReason,
          perform: onRunOnce
        )
      }

    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("harness.task-board.automation.manual")
  }

  private var controlBlockedReason: String? {
    guard isPresentationCurrent else { return "Automation status is updating" }
    return presentation.controlAvailability.controlBlockedReason
  }

  private func controlButton(
    action: TaskBoardAutomationInspectorAction,
    descriptor: TaskBoardActionButtonDescriptor,
    blockedReason: String?,
    perform: @escaping () -> Void
  ) -> some View {
    Button(action: perform) {
      HStack(spacing: HarnessMonitorTheme.spacingXS) {
        if activeAction == action {
          ProgressView()
            .controlSize(.small)
            .accessibilityHidden(true)
        } else {
          Image(systemName: descriptor.systemImage)
            .accessibilityHidden(true)
        }
        Text(descriptor.title)
          .lineLimit(1)
      }
    }
    .harnessActionButtonStyle(
      variant: descriptor.prominent ? .prominent : .bordered,
      tint: descriptor.tint
    )
    .harnessNativeFormControl()
    .controlSize(HarnessMonitorControlMetrics.compactControlSize)
    .disabled(blockedReason != nil || activeAction != nil)
    .help(blockedReason ?? descriptor.help)
    .accessibilityLabel(
      activeAction == action
        ? "\(descriptor.title), in progress"
        : descriptor.title
    )
    .accessibilityIdentifier(descriptor.accessibilityIdentifier)
  }
}
