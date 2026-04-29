import HarnessMonitorKit
import SwiftUI

struct AgentDetailAwaitingDecisionStrip: View {
  let count: Int
  let buttonAccessibilityIdentifier: String
  let action: () -> Void

  private var subtitle: String {
    let suffix = count == 1 ? "request" : "requests"
    return "\(count) permission \(suffix) pending"
  }

  var body: some View {
    HStack(alignment: .center, spacing: HarnessMonitorTheme.spacingMD) {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
        Text("Agent awaiting your decision")
          .scaledFont(.system(.headline, design: .rounded, weight: .semibold))
        Text(subtitle)
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      }
      Spacer(minLength: HarnessMonitorTheme.spacingMD)
      HarnessMonitorBadge(value: count.formatted())
      Button("Open in Decisions", action: action)
        .harnessActionButtonStyle(variant: .bordered, tint: nil)
        .controlSize(HarnessMonitorControlMetrics.compactControlSize)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier(buttonAccessibilityIdentifier)
    }
    .padding(HarnessMonitorTheme.spacingMD)
    .background(
      RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusMD, style: .continuous)
        .fill(HarnessMonitorTheme.caution.opacity(0.12))
    )
    .overlay {
      RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusMD, style: .continuous)
        .stroke(HarnessMonitorTheme.caution.opacity(0.35), lineWidth: 1)
    }
  }
}
