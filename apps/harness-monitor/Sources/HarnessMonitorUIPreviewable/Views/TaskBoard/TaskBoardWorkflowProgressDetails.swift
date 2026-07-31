import AppKit
import HarnessMonitorKit
import SwiftUI

struct TaskBoardWorkflowStepSelection: Identifiable {
  let step: TaskBoardDependencyTriageStep
  var id: UInt32 { step.order }
}

struct TaskBoardWorkflowAttemptSelection: Identifiable {
  let attempt: TaskBoardWorkflowAttemptProgress
  var id: String { "\(attempt.actionKey)#\(attempt.attempt)" }
}

struct TaskBoardWorkflowStepDetailSheet: View {
  let step: TaskBoardDependencyTriageStep
  @Environment(\.fontScale)
  private var fontScale

  var body: some View {
    TaskBoardWorkflowDetailSheetFrame(
      title: step.action.taskBoardDisplayTitle,
      subtitle: "Next step \(step.order)",
      systemImage: "\(max(1, min(step.order, 50))).circle"
    ) {
      Text(step.reason.withoutTrailingPeriod)
        .font(HarnessMonitorTextSize.scaledFont(.caption, by: fontScale))
        .foregroundStyle(HarnessMonitorTheme.ink)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

struct TaskBoardWorkflowAttemptDetailSheet: View {
  let attempt: TaskBoardWorkflowAttemptProgress
  @Environment(\.fontScale)
  private var fontScale

  var body: some View {
    TaskBoardWorkflowDetailSheetFrame(
      title: attempt.actionKey.taskBoardDisplayTitle,
      subtitle: "Attempt \(attempt.attempt) for this step",
      systemImage: attempt.state.systemImage,
      tint: attempt.state.tint
    ) {
      VStack(spacing: 0) {
        TaskBoardWorkflowValueRow(
          label: "Status",
          value: attempt.state.displayTitle
        )
        if let runtime = attempt.runtime {
          Divider()
          TaskBoardWorkflowValueRow(label: "Runtime", value: runtime)
        }
        if let model = attempt.model {
          Divider()
          TaskBoardWorkflowValueRow(label: "Model", value: model)
        }
        Divider()
        TaskBoardWorkflowValueRow(
          label: "Updated",
          value: attempt.updatedAt.taskBoardDisplayTimestamp
        )
      }
      .taskBoardWorkflowDetailCard()

      if let report = attempt.report, !report.isEmpty {
        proseSection(
          title: "Report",
          systemImage: "doc.text",
          content: report
        )
      }
      if let reason = attempt.terminalReason, !reason.isEmpty {
        proseSection(
          title: "Terminal reason",
          systemImage: "hand.raised.fill",
          content: reason
        )
      }
    }
  }

  private func proseSection(
    title: String,
    systemImage: String,
    content: String
  ) -> some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      TaskBoardWorkflowSectionHeader(title: title, systemImage: systemImage)
        .padding(.horizontal, HarnessMonitorTheme.spacingSM)
      Text(content.withoutTrailingPeriod)
        .font(HarnessMonitorTextSize.scaledFont(.caption, by: fontScale))
        .foregroundStyle(HarnessMonitorTheme.ink)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .padding(HarnessMonitorTheme.spacingSM)
        .frame(maxWidth: .infinity, alignment: .leading)
        .taskBoardWorkflowDetailCard()
    }
  }
}

private struct TaskBoardWorkflowDetailSheetFrame<Content: View>: View {
  let title: String
  let subtitle: String
  let systemImage: String
  var tint = HarnessMonitorTheme.secondaryInk
  let content: Content
  @Environment(\.dismiss)
  private var dismiss
  @Environment(\.fontScale)
  private var fontScale

  init(
    title: String,
    subtitle: String,
    systemImage: String,
    tint: Color = HarnessMonitorTheme.secondaryInk,
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.subtitle = subtitle
    self.systemImage = systemImage
    self.tint = tint
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .center, spacing: HarnessMonitorTheme.spacingSM) {
        Image(systemName: systemImage)
          .foregroundStyle(tint)
          .frame(width: 18, alignment: .center)
        VStack(alignment: .leading, spacing: 2) {
          Text(title)
            .font(captionSemibold)
          Text(subtitle)
            .font(captionFont)
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        }
        Spacer(minLength: HarnessMonitorTheme.spacingSM)
        Button("Done") {
          dismiss()
        }
        .keyboardShortcut(.cancelAction)
      }
      .padding(HarnessMonitorTheme.spacingMD)
      Divider()
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingLG) {
        content
      }
      .padding(HarnessMonitorTheme.spacingMD)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(width: 440)
    .background(Color(nsColor: .windowBackgroundColor))
    .fixedSize(horizontal: false, vertical: true)
    .accessibilityElement(children: .contain)
  }

  private var captionFont: Font {
    HarnessMonitorTextSize.scaledFont(.caption, by: fontScale)
  }

  private var captionSemibold: Font {
    HarnessMonitorTextSize.scaledFont(.caption.weight(.semibold), by: fontScale)
  }
}

extension View {
  fileprivate func taskBoardWorkflowDetailCard() -> some View {
    frame(maxWidth: .infinity, alignment: .leading)
      .background(HarnessMonitorTheme.ink.opacity(0.04), in: .rect(cornerRadius: 8))
      .overlay {
        RoundedRectangle(cornerRadius: 8)
          .strokeBorder(HarnessMonitorTheme.ink.opacity(0.1))
      }
  }
}
