import SwiftUI

private struct InteractiveCardButtonStyle: ButtonStyle {
  let cornerRadius: CGFloat
  let tint: Color?
  let isHovered: Bool
  @Environment(\.isEnabled)
  private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    let highlight = tint ?? .primary
    let fillOpacity = configuration.isPressed ? 0.12 : isHovered ? 0.08 : 0.04
    configuration.label
      .background {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .fill(highlight.opacity(fillOpacity))
      }
      .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
      .opacity(isEnabled ? (configuration.isPressed ? 0.92 : 1) : 0.4)
      .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
  }
}

private struct InteractiveCardHoverModifier: ViewModifier {
  let cornerRadius: CGFloat
  let tint: Color?
  @State private var isHovered = false

  func body(content: Content) -> some View {
    content
      .buttonStyle(
        InteractiveCardButtonStyle(
          cornerRadius: cornerRadius,
          tint: tint,
          isHovered: isHovered
        )
      )
      .onContinuousHover { phase in
        withAnimation(.easeOut(duration: 0.15)) {
          switch phase {
          case .active:
            isHovered = true
          case .ended:
            isHovered = false
          }
        }
      }
      .harnessUITestValue("chrome=content-card")
  }
}

extension View {
  func harnessInteractiveCardButtonStyle(
    cornerRadius: CGFloat = HarnessTheme.cornerRadiusMD,
    tint: Color? = nil
  ) -> some View {
    modifier(
      InteractiveCardHoverModifier(
        cornerRadius: cornerRadius,
        tint: tint
      )
    )
  }
}
