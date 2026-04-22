import HarnessMonitorKit
import SwiftUI

private enum ContentStatusBackdropLayout {
  static let gradientRadius: CGFloat = 380
  // Navigation buttons (back/forward) + spacing to title
  static let titleLeadingPadding: CGFloat = 75
}

public struct ContentStatusBackdrop: View {
  public let status: SessionStatus
  public let isStale: Bool

  @Environment(\.colorSchemeContrast)
  private var colorSchemeContrast

  public init(status: SessionStatus, isStale: Bool) {
    self.status = status
    self.isStale = isStale
  }

  private var color: Color {
    isStale ? HarnessMonitorTheme.ink.opacity(0.55) : statusColor(for: status)
  }

  private var tintOpacity: Double {
    colorSchemeContrast == .increased ? 0.28 : 0.22
  }

  public var body: some View {
    let radius = ContentStatusBackdropLayout.gradientRadius
    Color.clear
      .overlay(alignment: .topLeading) {
        Circle()
          .fill(
            RadialGradient(
              colors: [
                color.opacity(tintOpacity),
                color.opacity(tintOpacity * 0.5),
                .clear,
              ],
              center: .center,
              startRadius: 0,
              endRadius: radius
            )
          )
          .frame(width: radius * 2, height: radius * 2)
          .offset(
            x: ContentStatusBackdropLayout.titleLeadingPadding - radius,
            y: -radius
          )
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .ignoresSafeArea(.container, edges: .top)
      .backgroundExtensionEffect()
      .allowsHitTesting(false)
      .accessibilityHidden(true)
  }
}
