import HarnessMonitorKit
import SwiftUI

/// Single row in the Decisions sidebar. Severity dot + summary (wrapped to two lines) + the
/// short severity label. Renders as a button so selection taps flow through the sidebar's
/// `selectedDecisionID` binding.
struct DecisionRow: View {
  let decision: Decision
  let isSelected: Bool
  let fontScale: CGFloat
  let select: () -> Void

  private var severity: DecisionSeverity {
    DecisionSeverity(rawValue: decision.severityRaw) ?? .info
  }

  var body: some View {
    Button(action: select) {
      HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingSM) {
        Circle()
          .fill(severity.chipColor)
          .frame(width: 8, height: 8)
          .padding(.top, 6)
        VStack(alignment: .leading, spacing: 2) {
          Text(decision.summary)
            .scaledFont(.body)
            .lineLimit(2)
            .multilineTextAlignment(.leading)
          Text(severity.chipLabel)
            .scaledFont(.caption)
            .foregroundStyle(severity.chipColor)
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, HarnessMonitorTheme.spacingMD)
      .padding(.vertical, HarnessMonitorTheme.spacingSM * fontScale)
      .background(
        RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusSM, style: .continuous)
          .fill(isSelected ? HarnessMonitorTheme.accent.opacity(0.16) : Color.clear)
      )
      .contentShape(
        RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusSM, style: .continuous)
      )
    }
    .harnessDismissButtonStyle()
    .accessibilityIdentifier(HarnessMonitorAccessibility.decisionRow(decision.id))
    .accessibilityValue(isSelected ? "selected" : "not selected")
  }
}
