import SwiftUI

private struct SessionPaneLeadingSeparatorModifier: ViewModifier {
  @Environment(\.colorSchemeContrast)
  private var colorSchemeContrast

  private var separatorWidth: CGFloat {
    colorSchemeContrast == .increased ? 1.5 : 1
  }

  func body(content: Content) -> some View {
    content
      .overlay(alignment: .leading) {
        Color(nsColor: .separatorColor)
          .frame(width: separatorWidth)
          .allowsHitTesting(false)
          .accessibilityHidden(true)
      }
  }
}

extension View {
  func sessionPaneLeadingSeparator() -> some View {
    modifier(SessionPaneLeadingSeparatorModifier())
  }
}
