import HarnessMonitorPolicyCanvasAlgorithms
import SwiftUI

/// One changed go-live decision row: the action and scenario on the left, the
/// live -> draft verdict transition on the right. Read-only (no tap) and a
/// separate struct so the diff list redraws a single row when its verdicts
/// change rather than the whole list.
struct PolicyCanvasGoLiveDiffRow: View {
  let model: PolicyCanvasGoLiveDiffRowModel

  var body: some View {
    HStack(spacing: 10) {
      VStack(alignment: .leading, spacing: 2) {
        Text(model.actionTitle)
          .scaledFont(.callout.weight(.semibold))
          .foregroundStyle(PolicyCanvasVisualStyle.primaryText)
          .lineLimit(1)
        Text(model.scenarioName)
          .scaledFont(.caption2)
          .foregroundStyle(PolicyCanvasVisualStyle.tertiaryText)
          .lineLimit(1)
      }

      Spacer(minLength: 8)

      transition
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
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityLabel)
  }

  private var transition: some View {
    HStack(spacing: 6) {
      if let liveVerdict = model.liveVerdict {
        PolicyCanvasVerdictPill(verdict: liveVerdict)
      } else {
        Text("new")
          .scaledFont(.caption2.weight(.medium))
          .foregroundStyle(PolicyCanvasVisualStyle.tertiaryText)
      }
      Image(systemName: "arrow.right")
        .scaledFont(.caption2)
        .foregroundStyle(PolicyCanvasVisualStyle.tertiaryText)
      PolicyCanvasVerdictPill(verdict: model.draftVerdict)
    }
    .fixedSize()
  }

  private var accessibilityLabel: String {
    let live = model.liveVerdict?.label ?? "no live decision"
    return
      "\(model.actionTitle), scenario \(model.scenarioName): \(live) becomes \(model.draftVerdict.label)"
  }
}
