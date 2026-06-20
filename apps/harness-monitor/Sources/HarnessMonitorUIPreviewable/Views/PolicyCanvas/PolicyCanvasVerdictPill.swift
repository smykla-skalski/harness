import HarnessMonitorPolicyCanvasAlgorithms
import SwiftUI

/// Shared tone-coded verdict chip: an icon + label tinted by the verdict's tone.
/// One definition keeps the decision-matrix and go-live-diff pills visually
/// identical, so a tone or icon change lands in both at once.
struct PolicyCanvasVerdictPill: View {
  let verdict: PolicyCanvasDecisionVerdict

  var body: some View {
    Label(verdict.label, systemImage: verdict.systemImage)
      .scaledFont(.caption2.weight(.semibold))
      .lineLimit(1)
      .foregroundStyle(verdict.tone.tint)
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(verdict.tone.background, in: .capsule)
      .overlay {
        Capsule().strokeBorder(verdict.tone.border, lineWidth: 1)
      }
      .fixedSize()
  }
}
