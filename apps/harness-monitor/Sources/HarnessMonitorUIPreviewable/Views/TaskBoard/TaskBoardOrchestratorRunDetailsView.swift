import HarnessMonitorKit
import SwiftUI

struct TaskBoardOrchestratorRunDetailsView: View {
  let run: TaskBoardOrchestratorRunSummary

  @Environment(\.fontScale)
  private var fontScale

  private var captionFont: Font {
    HarnessMonitorTextSize.scaledFont(.caption, by: fontScale)
  }

  private var captionSemibold: Font {
    HarnessMonitorTextSize.scaledFont(.caption.weight(.semibold), by: fontScale)
  }

  private var hasContent: Bool {
    run.error != nil || !run.policyTraceIds.isEmpty
  }

  var body: some View {
    if hasContent {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
        if let error = run.error {
          errorContent(error)
        }
        if !run.policyTraceIds.isEmpty {
          traceContent
        }
      }
      .padding(.top, HarnessMonitorTheme.spacingXS)
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("harness.task-board.orchestrator.last-run-details")
    }
  }

  private func errorContent(_ error: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Label {
        Text(failureTitle)
          .font(captionSemibold)
      } icon: {
        Image(systemName: "exclamationmark.triangle.fill")
          .accessibilityHidden(true)
      }
      .foregroundStyle(HarnessMonitorTheme.danger)

      Text(verbatim: error)
        .font(captionFont)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("harness.task-board.orchestrator.last-run-error")
    }
  }

  private var traceContent: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text("Policy trace IDs")
        .font(captionSemibold)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      Text(verbatim: run.policyTraceIds.joined(separator: ", "))
        .font(captionFont.monospaced())
        .foregroundStyle(HarnessMonitorTheme.tertiaryInk)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("harness.task-board.orchestrator.policy-trace-ids")
    }
  }

  private var failureTitle: String {
    guard let stage = TaskBoardOrchestratorPresentation.failedStage(for: run) else {
      return "Last run error"
    }
    return "Failed during \(stage.rawValue)"
  }
}
