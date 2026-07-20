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
      .padding(.horizontal, HarnessMonitorTheme.pillPaddingH)
      .harnessOpticallyBalancedVerticalPadding(HarnessMonitorTheme.pillPaddingV)
      .harnessControlPillGlass(tint: HarnessMonitorTheme.caution)
      .help("Manual steps run live against the board")
      .accessibilityLabel("Live operations")
      .accessibilityHint("Manual steps run live against the board")
      .accessibilityIdentifier("harness.task-board.step.live-mode")
  }
}

/// The automation-context footer of the manual-steps card.
///
/// `DisclosureGroup` only hit-tests its triangle on macOS, so the label carries
/// its own full-width button and hover highlight - otherwise the row reads as
/// static text and the only way in is a 12pt chevron. A button rather than a
/// tap gesture so the row stays tab-reachable and keyboard-activatable.
struct TaskBoardStepContextDisclosure: View {
  let store: HarnessMonitorStore
  let workspace: PolicyCanvasWorkspace?
  let heldDispatches: TaskBoardHeldDispatchSummary
  let refreshID: TaskBoardApprovalGrantRefreshID
  let isDisabled: Bool
  @Binding var isExpanded: Bool

  @Environment(\.fontScale)
  private var fontScale
  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion
  @State private var isHovered = false

  private var labelFont: Font {
    HarnessMonitorTextSize.scaledFont(.callout.weight(.semibold), by: fontScale)
  }

  var body: some View {
    DisclosureGroup(isExpanded: $isExpanded) {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingMD) {
        TaskBoardApprovalGrantsView(
          store: store,
          workspace: workspace,
          refreshID: refreshID,
          isDisabled: isDisabled
        )
        HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingXL) {
          TaskBoardHeldDispatchesView(summary: heldDispatches)
            .frame(maxWidth: .infinity, alignment: .topLeading)
          TaskBoardPolicyGuardsView(workspace: workspace)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
      }
      .padding(.top, HarnessMonitorTheme.spacingSM)
    } label: {
      Button {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
          isExpanded.toggle()
        }
      } label: {
        Label("Automation context", systemImage: "gearshape")
          .font(labelFont)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.vertical, HarnessMonitorTheme.spacingXS)
          .padding(.horizontal, HarnessMonitorTheme.spacingSM)
          .background(
            HarnessMonitorTheme.accent.opacity(isHovered ? 0.08 : 0),
            in: .rect(cornerRadius: HarnessMonitorTheme.cornerRadiusSM)
          )
          .contentShape(.rect)
      }
      .buttonStyle(.plain)
      .onHover { isHovered = $0 }
    }
    .accessibilityIdentifier("harness.task-board.step.context")
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
