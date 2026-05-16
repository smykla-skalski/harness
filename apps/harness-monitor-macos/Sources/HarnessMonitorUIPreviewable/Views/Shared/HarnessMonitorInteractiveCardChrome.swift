import SwiftUI

enum InteractiveCardHoverState {
  static func resolve(current: Bool, isHovering: Bool) -> Bool? {
    current == isHovering ? nil : isHovering
  }
}

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
          // Animate the background fill only on opacity changes, not the
          // whole view tree. The previous `withAnimation` wrapper around
          // `isHovered = nextHoverState` fired a SwiftUI Transaction on
          // every hover transition; in a list with N cards a single scroll
          // pass would propagate 2N Transactions through View Responders.
          // Scoping animation to the value here keeps the visual feel
          // without the global cascade (r17 audit: View Transform → View
          // Responders edges 67k).
          .animation(.easeOut(duration: 0.15), value: fillOpacity)
      }
      .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
      .opacity(isEnabled ? (configuration.isPressed ? 0.92 : 1) : 0.4)
      .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
  }
}

private struct InteractiveCardHoverModifier: ViewModifier {
  let cornerRadius: CGFloat
  let tint: Color?
  let extraHoverHint: Bool
  @State private var isHovered = false

  func body(content: Content) -> some View {
    content
      .buttonStyle(
        InteractiveCardButtonStyle(
          cornerRadius: cornerRadius,
          tint: tint,
          isHovered: isHovered || extraHoverHint
        )
      )
      .onHover { isHovering in
        guard
          let nextHoverState = InteractiveCardHoverState.resolve(
            current: isHovered,
            isHovering: isHovering
          )
        else {
          return
        }
        isHovered = nextHoverState
      }
      .harnessUITestValue("chrome=content-card")
  }
}

extension View {
  func harnessInteractiveCardButtonStyle(
    cornerRadius: CGFloat = HarnessMonitorTheme.cornerRadiusMD,
    tint: Color? = nil,
    extraHoverHint: Bool = false
  ) -> some View {
    modifier(
      InteractiveCardHoverModifier(
        cornerRadius: cornerRadius,
        tint: tint,
        extraHoverHint: extraHoverHint
      )
    )
  }
}
