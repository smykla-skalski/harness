import HarnessMonitorKit
import SwiftUI

struct AgentAttentionBadge: View {
  let count: Int
  let accessibilityIdentifier: String?
  let action: () -> Void

  @ViewBuilder var body: some View {
    let button = Button(action: action) {
      HStack(spacing: 4) {
        Image(systemName: "hand.raised.fill")
          .imageScale(.small)
        Text(count.formatted())
          .monospacedDigit()
      }
      .scaledFont(.caption.bold())
      .foregroundStyle(HarnessMonitorTheme.onContrast)
      .harnessPillPadding()
      .background(
        Capsule(style: .continuous)
          .fill(HarnessMonitorTheme.caution)
      )
    }
    .harnessDismissButtonStyle()
    .help("Open pending decisions")

    if let accessibilityIdentifier {
      button.accessibilityIdentifier(accessibilityIdentifier)
    } else {
      button
    }
  }
}
