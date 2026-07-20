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
  private var placeholderFont: Font {
    HarnessMonitorTextSize.scaledFont(.body, by: fontScale)
  }
  private var badgeFont: Font {
    HarnessMonitorTextSize.scaledFont(.caption.weight(.semibold), by: fontScale)
  }

  var body: some View {
    HStack(alignment: .center, spacing: HarnessMonitorTheme.spacingSM) {
      HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.spacingSM) {
        Label(isPicked ? "Picked item:" : "Current target:", systemImage: "scope")
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

/// Feedback for the automation-context row. The row sits directly on the
/// manual-steps card, so it rests fully transparent and only tints while the
/// pointer is over it or it is held down.
private struct TaskBoardStepContextRowButtonStyle: ButtonStyle {
  let isHovered: Bool

  @Environment(\.isEnabled)
  private var isEnabled

  private var shape: RoundedRectangle {
    RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusSM, style: .continuous)
  }

  private func fillOpacity(isPressed: Bool) -> Double {
    isPressed ? 0.10 : isHovered ? 0.06 : 0
  }

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .background {
        shape.fill(
          HarnessMonitorTheme.ink.opacity(fillOpacity(isPressed: configuration.isPressed))
        )
      }
      .contentShape(shape)
      .opacity(isEnabled ? 1 : 0.4)
      .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
  }
}

/// The automation-context footer of the manual-steps card.
///
/// Hand-rolled rather than a `DisclosureGroup`: that container owns its
/// triangle and only ever hands the label the space to the right of it, so the
/// row's hover tint could never reach the chevron. Expanding is deliberately
/// instant - see the `nil` animation below.
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

  private var chevronWidth: CGFloat {
    12 * SessionWindowFontScale.metricsScale(for: fontScale)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      headerRow
      if isExpanded {
        expandedBody
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    // Expanding is instant on purpose. Keyed rather than removed so an
    // animation added to an ancestor later cannot silently reanimate it.
    .animation(nil, value: isExpanded)
    .accessibilityIdentifier("harness.task-board.step.context")
  }

  private var headerRow: some View {
    Button {
      isExpanded.toggle()
    } label: {
      HStack(spacing: HarnessMonitorTheme.spacingXS) {
        // Swapped rather than rotated so the glyph cannot animate either.
        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
          .font(labelFont)
          .foregroundStyle(.secondary)
          .frame(width: chevronWidth)
          .accessibilityHidden(true)
        Label("Automation context", systemImage: "gearshape")
          .font(labelFont)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.vertical, HarnessMonitorTheme.spacingXS)
      .padding(.horizontal, HarnessMonitorTheme.spacingSM)
    }
    .buttonStyle(TaskBoardStepContextRowButtonStyle(isHovered: isHovered))
    .onHover { hovering in
      withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
        isHovered = hovering
      }
    }
    // The row is a plain button, so VoiceOver has no expanded state to read
    // unless it carries one.
    .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
    .accessibilityHint("Shows approval grants, held dispatches, and policy guards")
  }

  private var expandedBody: some View {
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
    // Lines the body up under the row label instead of the chevron, which is
    // what the DisclosureGroup indent used to do.
    .padding(.leading, chevronWidth + HarnessMonitorTheme.spacingXS + HarnessMonitorTheme.spacingSM)
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
