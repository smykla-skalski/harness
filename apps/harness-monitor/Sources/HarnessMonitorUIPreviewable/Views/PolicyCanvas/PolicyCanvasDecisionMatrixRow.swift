import HarnessMonitorKit
import HarnessMonitorPolicyCanvasAlgorithms
import SwiftUI

/// One decision-matrix row: the action name, a tone-coded verdict pill, the
/// daemon reason code, and a tap target that lights the decision's path on the
/// canvas. A separate struct so a row tap never invalidates its siblings.
struct PolicyCanvasDecisionMatrixRow: View {
  let model: PolicyCanvasDecisionMatrixRowModel
  let focusDecision: @MainActor ([String]) -> Void

  var body: some View {
    Button {
      focusDecision(model.visitedNodeIds)
    } label: {
      rowContent
    }
    .harnessPlainButtonStyle()
    .disabled(model.visitedNodeIds.isEmpty)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(model.actionTitle): \(model.verdict.label)")
    .accessibilityIdentifier(
      HarnessMonitorAccessibility.policyCanvasDecisionRow(model.actionRaw)
    )
  }

  private var rowContent: some View {
    HStack(spacing: 10) {
      verdictPill

      VStack(alignment: .leading, spacing: 2) {
        Text(model.actionTitle)
          .scaledFont(.callout.weight(.semibold))
          .foregroundStyle(PolicyCanvasVisualStyle.primaryText)
          .lineLimit(1)

        if !model.reasonCode.isEmpty {
          Text(model.reasonCode.replacingOccurrences(of: "_", with: " "))
            .scaledFont(.caption2)
            .foregroundStyle(PolicyCanvasVisualStyle.tertiaryText)
            .lineLimit(1)
        }
      }

      Spacer(minLength: 0)

      if !model.visitedNodeIds.isEmpty {
        Image(systemName: "scope")
          .scaledFont(.caption)
          .foregroundStyle(PolicyCanvasVisualStyle.tertiaryText)
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      PolicyCanvasVisualStyle.surface,
      in: RoundedRectangle(cornerRadius: HarnessMonitorTheme.pillCornerRadius, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: HarnessMonitorTheme.pillCornerRadius, style: .continuous)
        .stroke(PolicyCanvasVisualStyle.subtleBorder, lineWidth: 1)
    }
    .contentShape(Rectangle())
  }

  private var verdictPill: some View {
    Label(model.verdict.label, systemImage: model.verdict.systemImage)
      .scaledFont(.caption2.weight(.semibold))
      .lineLimit(1)
      .foregroundStyle(model.verdict.tone.tint)
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(model.verdict.tone.background, in: .capsule)
      .overlay {
        Capsule().strokeBorder(model.verdict.tone.border, lineWidth: 1)
      }
      .fixedSize()
  }
}
