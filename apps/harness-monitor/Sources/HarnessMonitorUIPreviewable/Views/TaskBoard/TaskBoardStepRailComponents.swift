import HarnessMonitorKit
import SwiftUI

struct TaskBoardStepRailTargetView: View {
  let item: TaskBoardItem?
  let isPicked: Bool

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.spacingSM) {
      Label(isPicked ? "Picked item" : "Current target", systemImage: "scope")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      if let item {
        Text(item.title)
          .font(.body.weight(.semibold))
          .lineLimit(1)
        Text(item.id)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      } else {
        Text("No selected or ready Todo item")
          .font(.body)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct TaskBoardStepControl: View {
  let step: Int
  let title: String
  let detail: String
  let systemImage: String
  let tint: Color
  let isEnabled: Bool
  let isBusy: Bool
  let isComplete: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingSM) {
        Text("\(step)")
          .font(.caption.bold().monospacedDigit())
          .frame(width: 22, height: 22)
          .background(tint.opacity(0.16), in: .circle)
        VStack(alignment: .leading, spacing: 2) {
          Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
          Text(detail)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .multilineTextAlignment(.leading)
        }
        Spacer(minLength: 0)
        if isBusy {
          ProgressView()
            .controlSize(.small)
        } else if isComplete {
          Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(tint)
            .accessibilityLabel("Complete")
        }
      }
      .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
      .contentShape(.rect)
    }
    .harnessActionButtonStyle(variant: .bordered, tint: tint)
    .disabled(!isEnabled)
    .accessibilityIdentifier("harness.task-board.step.\(step)")
  }
}

struct TaskBoardStepPromptPreview: View {
  let prompt: String

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Label("Exact spawn instructions", systemImage: "text.quote")
        .font(.caption.weight(.semibold))
      ScrollView {
        Text(verbatim: prompt)
          .font(.system(.caption, design: .monospaced))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxHeight: 220)
      .padding(HarnessMonitorTheme.spacingSM)
      .background(HarnessMonitorTheme.ink.opacity(0.05), in: .rect(cornerRadius: 8))
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityIdentifier("harness.task-board.step.prompt")
  }
}

struct TaskBoardHeldDispatchesView: View {
  let summary: TaskBoardHeldDispatchSummary

  var body: some View {
    DisclosureGroup("Held for delivery (\(summary.count))") {
      if summary.items.isEmpty {
        Text("No held dispatches")
          .foregroundStyle(.secondary)
      } else {
        VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
          ForEach(summary.items, id: \.intentId) { item in
            VStack(alignment: .leading, spacing: 2) {
              Text(item.boardItemId)
                .font(.caption.weight(.semibold))
              Text("\(item.sessionId) · \(item.workItemId)")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            }
          }
        }
        .padding(.top, HarnessMonitorTheme.spacingXS)
      }
    }
    .font(.caption)
    .accessibilityIdentifier("harness.task-board.step.held-dispatches")
  }
}

struct TaskBoardPolicyGuardsView: View {
  let workspace: PolicyCanvasWorkspace?

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Text("Policy guards")
        .font(.caption.weight(.semibold))
      policyGuardStatus(
        "Require a live policy before spawn",
        isEnabled: workspace?.spawnRequiresLivePolicy ?? false,
        enabledTint: HarnessMonitorTheme.caution
      )
      policyGuardStatus(
        "Spawn kill switch",
        isEnabled: workspace?.spawnKillSwitch ?? false,
        enabledTint: HarnessMonitorTheme.danger
      )
    }
    .foregroundStyle(workspace == nil ? .secondary : .primary)
    .accessibilityIdentifier("harness.task-board.step.policy-guards")
  }

  private func policyGuardStatus(
    _ title: String,
    isEnabled: Bool,
    enabledTint: Color
  ) -> some View {
    HStack(spacing: HarnessMonitorTheme.spacingXS) {
      Image(systemName: isEnabled ? "checkmark.circle.fill" : "circle")
        .foregroundStyle(isEnabled ? enabledTint : .secondary)
      Text(title)
      Spacer(minLength: 0)
      Text(isEnabled ? "On" : "Off")
        .foregroundStyle(isEnabled ? enabledTint : .secondary)
    }
    .font(.caption)
  }
}
