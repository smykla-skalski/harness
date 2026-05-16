import SwiftUI

/// Centered placeholder shown while the canvas has zero nodes and zero
/// groups. Closes the gulf-of-execution by naming the canvas and pointing
/// at the palette as the next action. Disappears as soon as the first node
/// or group lands, so we don't need an explicit dismissal affordance.
///
/// The placeholder is rendered as a workspace overlay with `allowsHitTesting`
/// false in the caller; clicks pass through to the canvas underneath so the
/// user can still drop a palette item on the empty canvas without aiming
/// around the placeholder.
struct PolicyCanvasEmptyStatePlaceholder: View {
  let viewModel: PolicyCanvasViewModel

  var body: some View {
    if viewModel.isEmpty {
      VStack(spacing: 18) {
        Image(systemName: "rectangle.3.group.bubble")
          .scaledFont(.system(size: 48, weight: .light))
          .foregroundStyle(.white.opacity(0.88))
          .accessibilityHidden(true)

        VStack(spacing: 8) {
          Text("Empty policy canvas")
            .scaledFont(.title2.weight(.semibold))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)

          Text("Compose a policy graph by adding nodes from the palette.")
            .scaledFont(.callout)
            // .white.opacity(0.78) hits WCAG AA on the canvas's dark background
            // (~9.4:1); .opacity(0.48) used elsewhere fails the bar (~3.0:1)
            // per the contrast audit cited in the Wave 1B accessibility plan.
            .foregroundStyle(.white.opacity(0.78))
            .multilineTextAlignment(.center)
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
        }

        Text("Tip: drag a tool from the left rail onto the canvas to start.")
          .scaledFont(.caption.weight(.medium))
          .foregroundStyle(.white.opacity(0.78))
          .multilineTextAlignment(.center)
          .lineLimit(2)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: 360)
          .padding(.horizontal, 16)
          .padding(.vertical, 8)
          .background(
            .black.opacity(0.36),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
          )
      }
      .frame(width: 440)
      .frame(minHeight: 280)
      .padding(.horizontal, 40)
      .padding(.vertical, 32)
      .accessibilityElement(children: .combine)
      .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasEmptyState)
    }
  }
}
