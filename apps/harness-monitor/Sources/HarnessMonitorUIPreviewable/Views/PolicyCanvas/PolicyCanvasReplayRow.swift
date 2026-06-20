import HarnessMonitorPolicyCanvasAlgorithms
import SwiftUI

/// One replay row: the action and replay status on the leading edge, the
/// historical -> draft verdict transition on the trailing edge. Tapping lights
/// the draft decision's path via the shared focus-decision closure. A separate
/// struct so the list redraws a single row when its verdicts change rather than
/// the whole list.
struct PolicyCanvasReplayRow: View {
  let row: PolicyCanvasReplayRowModel
  let focusDecision: @MainActor ([String]) -> Void

  var body: some View {
    Button {
      focusDecision(row.visitedNodeIds)
    } label: {
      HStack(spacing: 8) {
        VStack(alignment: .leading, spacing: 2) {
          Text(row.actionTitle)
            .scaledFont(.caption.weight(.medium))
            .lineLimit(1)
            .foregroundStyle(PolicyCanvasVisualStyle.primaryText)
          Text(statusLabel)
            .scaledFont(.caption2)
            .lineLimit(1)
            .foregroundStyle(statusTint)
        }
        Spacer(minLength: 8)
        transition
      }
      .contentShape(Rectangle())
    }
    .harnessPlainButtonStyle()
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityLabel)
  }

  private var transition: some View {
    HStack(spacing: 6) {
      PolicyCanvasVerdictPill(verdict: row.historicalVerdict)
      Image(systemName: "arrow.right")
        .scaledFont(.caption2)
        .foregroundStyle(PolicyCanvasVisualStyle.tertiaryText)
      PolicyCanvasVerdictPill(verdict: row.draftVerdict)
    }
    .fixedSize()
  }

  private var statusLabel: String {
    if row.insufficientEvidence {
      return "Insufficient evidence"
    }
    return row.changed ? "Changed" : "Unchanged"
  }

  private var statusTint: Color {
    if row.insufficientEvidence {
      return PolicyCanvasVisualStyle.tertiaryText
    }
    return row.changed ? PolicyCanvasWorkflowTone.warning.tint : PolicyCanvasVisualStyle.tertiaryText
  }

  private var accessibilityLabel: String {
    let status =
      row.insufficientEvidence
      ? "insufficient evidence" : (row.changed ? "changed" : "unchanged")
    return
      "\(row.actionTitle), \(status): history \(row.historicalVerdict.label), "
      + "draft \(row.draftVerdict.label)"
  }
}
