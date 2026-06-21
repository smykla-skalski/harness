import HarnessMonitorKit
import HarnessMonitorPolicyCanvasAlgorithms
import SwiftUI

/// One decision-matrix row: the action name, a tone-coded verdict pill, the
/// humanized reason (shown only when it adds something the verdict does not),
/// and a tap target that traces the decision's path on the canvas. A separate
/// struct so a row tap never invalidates its siblings.
struct PolicyCanvasDecisionMatrixRow: View {
  let model: PolicyCanvasDecisionMatrixRowModel
  let focusDecision: @MainActor ([String]) -> Void

  @State private var isHovering = false

  /// A row can trace a path only when the simulation recorded the nodes it
  /// visited; otherwise the row is a plain read-only readout.
  private var isInteractive: Bool { !model.visitedNodeIds.isEmpty }

  var body: some View {
    Button(action: trace) {
      rowContent
    }
    .harnessPlainButtonStyle()
    .disabled(!isInteractive)
    .onHover { isHovering = $0 }
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
      PolicyCanvasVerdictPill(verdict: model.verdict)

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

      Spacer(minLength: 0)

      if isInteractive {
        Image(systemName: "location.viewfinder")
          .scaledFont(.caption)
          .foregroundStyle(
            isHovering ? PolicyCanvasVisualStyle.activeTint : PolicyCanvasVisualStyle.tertiaryText
          )
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      isInteractive && isHovering
        ? PolicyCanvasVisualStyle.controlHoverSurface : PolicyCanvasVisualStyle.surface,
      in: RoundedRectangle(cornerRadius: HarnessMonitorTheme.pillCornerRadius, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: HarnessMonitorTheme.pillCornerRadius, style: .continuous)
        .stroke(
          isInteractive && isHovering
            ? PolicyCanvasVisualStyle.border : PolicyCanvasVisualStyle.subtleBorder,
          lineWidth: 1
        )
    }
    .contentShape(Rectangle())
  }
}
