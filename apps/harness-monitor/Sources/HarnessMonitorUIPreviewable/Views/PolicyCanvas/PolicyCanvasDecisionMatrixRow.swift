import HarnessMonitorKit
import HarnessMonitorPolicyCanvasAlgorithms
import SwiftUI

/// One decision-matrix row: the action name on the leading edge (so every row's
/// name shares a left axis and the list scans as a column), the humanized reason
/// when it adds something the verdict does not, a trailing tone-coded verdict
/// pill, and a trace affordance. A separate struct so a row tap never
/// invalidates its siblings. No per-row hover state: an `onHover` on every row
/// fires its tracking area as the rows translate under a stationary cursor
/// during a scroll, invalidating row bodies and making the list choppy - the
/// persistent active accent and the always-visible trace icon carry the
/// affordance instead.
struct PolicyCanvasDecisionMatrixRow: View {
  let model: PolicyCanvasDecisionMatrixRowModel
  /// True when this is the row the user last traced, so it keeps a persistent
  /// accent after the tap effect lands on the canvas elsewhere.
  let isActive: Bool
  let focusDecision: @MainActor ([String]) -> Void

  /// A row can trace a path only when the simulation recorded the nodes it
  /// visited; otherwise the row is a plain read-only readout.
  private var isInteractive: Bool { !model.visitedNodeIds.isEmpty }

  var body: some View {
    Button(action: trace) {
      rowContent
    }
    .harnessPlainButtonStyle()
    .disabled(!isInteractive)
    .help(isInteractive ? "Show this decision's path on the canvas" : "")
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityHint(isInteractive ? "Traces this decision on the canvas" : "")
    .accessibilityIdentifier(
      HarnessMonitorAccessibility.policyCanvasDecisionRow(model.id)
    )
  }

  /// Announce the navigation for VoiceOver - the visible effect lands on the
  /// canvas elsewhere, so without this the action is silent to a screen reader.
  private func trace() {
    AccessibilityNotification.Announcement("Tracing \(model.actionTitle) on the canvas").post()
    focusDecision(model.visitedNodeIds)
  }

  private var reasonText: String? {
    PolicyCanvasDecisionReason.explanation(reasonCode: model.reasonCode)
  }

  /// The seeded scenarios are named after their action, so the subtitle would
  /// just repeat the title ("Sync" over "Sync"). Show it only when it differs.
  private var showsScenarioName: Bool {
    !model.scenarioName.isEmpty
      && model.scenarioName.caseInsensitiveCompare(model.actionTitle) != .orderedSame
  }

  private var accessibilityLabel: String {
    guard let reasonText else {
      return "\(model.actionTitle): \(model.verdict.label)"
    }
    return "\(model.actionTitle): \(model.verdict.label), \(reasonText)"
  }

  private var rowContent: some View {
    HStack(spacing: 10) {
      VStack(alignment: .leading, spacing: 2) {
        Text(model.actionTitle)
          .scaledFont(.callout.weight(.semibold))
          .foregroundStyle(PolicyCanvasVisualStyle.primaryText)
          .lineLimit(1)

        if showsScenarioName {
          Text(model.scenarioName)
            .scaledFont(.caption2)
            .foregroundStyle(PolicyCanvasVisualStyle.tertiaryText)
            .lineLimit(1)
        }

        if let reasonText {
          Text(reasonText)
            .scaledFont(.caption2)
            .foregroundStyle(PolicyCanvasVisualStyle.tertiaryText)
            .lineLimit(1)
        }
      }

      Spacer(minLength: 8)

      PolicyCanvasVerdictPill(verdict: model.verdict)
        .accessibilityHidden(true)

      if isInteractive {
        Image(systemName: "point.3.connected.trianglepath.dotted")
          .scaledFont(.caption)
          .foregroundStyle(
            isActive
              ? PolicyCanvasVisualStyle.activeTint : PolicyCanvasVisualStyle.tertiaryText
          )
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      rowBackground,
      in: RoundedRectangle(cornerRadius: HarnessMonitorTheme.pillCornerRadius, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: HarnessMonitorTheme.pillCornerRadius, style: .continuous)
        .stroke(rowBorderColor, lineWidth: isActive ? 1.5 : 1)
    }
    .contentShape(Rectangle())
  }

  private var rowBackground: Color {
    isActive
      ? PolicyCanvasVisualStyle.activeTint.opacity(0.12) : PolicyCanvasVisualStyle.surface
  }

  private var rowBorderColor: Color {
    isActive ? PolicyCanvasVisualStyle.activeTint : PolicyCanvasVisualStyle.subtleBorder
  }
}
