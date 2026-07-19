import HarnessMonitorKit
import SwiftUI

struct TaskBoardStepRailTargetView: View {
  let item: TaskBoardItem?
  let isPicked: Bool

  @Environment(\.fontScale)
  private var fontScale

  private var labelFont: Font {
    HarnessMonitorTextSize.scaledFont(.callout.weight(.semibold), by: fontScale)
  }
  private var titleFont: Font {
    HarnessMonitorTextSize.scaledFont(.body.weight(.semibold), by: fontScale)
  }
  private var idFont: Font {
    HarnessMonitorTextSize.scaledFont(.callout.monospaced(), by: fontScale)
  }
  private var placeholderFont: Font {
    HarnessMonitorTextSize.scaledFont(.body, by: fontScale)
  }
  private var badgeFont: Font {
    HarnessMonitorTextSize.scaledFont(.caption.weight(.semibold), by: fontScale)
  }

  var body: some View {
    HStack(alignment: .center, spacing: HarnessMonitorTheme.spacingSM) {
      HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.spacingSM) {
        Label(isPicked ? "Picked item" : "Current target", systemImage: "scope")
          .font(labelFont)
          .foregroundStyle(.secondary)
        identity
      }
      Spacer(minLength: HarnessMonitorTheme.spacingSM)
      liveBadge
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder private var identity: some View {
    if let item {
      Text(item.title)
        .font(titleFont)
        .lineLimit(1)
      Text(item.id)
        .font(idFont)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
    } else {
      Text("No selected or ready Todo item")
        .font(placeholderFont)
        .foregroundStyle(.secondary)
    }
  }

  private var liveBadge: some View {
    Label("Live", systemImage: "bolt.fill")
      .font(badgeFont)
      .foregroundStyle(HarnessMonitorTheme.caution)
      .harnessControlPillGlass(tint: HarnessMonitorTheme.caution)
      .help("Manual steps run live against the board")
      .accessibilityLabel("Live operations")
      .accessibilityHint("Manual steps run live against the board")
      .accessibilityIdentifier("harness.task-board.step.live-mode")
  }
}

struct TaskBoardStepPromptPreview: View {
  let prompt: String

  @Environment(\.fontScale)
  private var fontScale

  private var labelFont: Font {
    HarnessMonitorTextSize.scaledFont(.callout.weight(.semibold), by: fontScale)
  }
  private var promptFont: Font {
    HarnessMonitorTextSize.scaledFont(.system(.callout, design: .monospaced), by: fontScale)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Label("Exact spawn instructions", systemImage: "text.quote")
        .font(labelFont)
      ScrollView {
        Text(verbatim: prompt)
          .font(promptFont)
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

  @Environment(\.fontScale)
  private var fontScale

  private var groupFont: Font {
    HarnessMonitorTextSize.scaledFont(.callout, by: fontScale)
  }
  private var itemTitleFont: Font {
    HarnessMonitorTextSize.scaledFont(.callout.weight(.semibold), by: fontScale)
  }
  private var itemDetailFont: Font {
    HarnessMonitorTextSize.scaledFont(.callout.monospaced(), by: fontScale)
  }

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
                .font(itemTitleFont)
              Text("\(item.sessionId) · \(item.workItemId)")
                .font(itemDetailFont)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            }
          }
        }
        .padding(.top, HarnessMonitorTheme.spacingXS)
      }
    }
    .font(groupFont)
    .accessibilityIdentifier("harness.task-board.step.held-dispatches")
  }
}

struct TaskBoardPolicyGuardsView: View {
  let workspace: PolicyCanvasWorkspace?

  @Environment(\.fontScale)
  private var fontScale

  private var titleFont: Font {
    HarnessMonitorTextSize.scaledFont(.callout.weight(.semibold), by: fontScale)
  }
  private var rowFont: Font {
    HarnessMonitorTextSize.scaledFont(.callout, by: fontScale)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Text("Policy guards")
        .font(titleFont)
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
    .font(rowFont)
  }
}
