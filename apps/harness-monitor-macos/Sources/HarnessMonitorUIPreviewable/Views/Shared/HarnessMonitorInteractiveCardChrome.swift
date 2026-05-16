import SwiftUI

extension EnvironmentValues {
  /// True while an ancestor scroll surface is actively tracking or decelerating.
  /// Per-card `.onHover` registration is suppressed during this window so the
  /// cursor-responder retarget cascade does not fan out across N visible cards
  /// per scroll tick (r18 audit: View Transform → View Responders 66k edges
  /// dominated by per-card tracking-area recomputes during scroll).
  @Entry var harnessIsScrolling: Bool = false
}

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
  @Environment(\.harnessIsScrolling)
  private var isScrolling

  func body(content: Content) -> some View {
    content
      .buttonStyle(
        InteractiveCardButtonStyle(
          cornerRadius: cornerRadius,
          tint: tint,
          isHovered: isHovered || extraHoverHint
        )
      )
      .modifier(
        InteractiveCardHoverGate(
          isScrolling: isScrolling,
          isHovered: $isHovered
        )
      )
      .harnessUITestValue("chrome=content-card")
  }
}

/// Conditionally installs `.onHover` based on the ancestor scroll phase. While
/// a scroll is active the modifier branch resolves to a no-op so SwiftUI tears
/// down the tracking responder for the duration of the gesture; when the scroll
/// idles the responder is reattached and SwiftUI fires the current hover state
/// on the next layout pass. Hover state is intentionally left at its last
/// resolved value during the scroll - the cards are in motion so the lingering
/// fill blends with the gesture, and `.onHover` re-evaluates against the
/// current pointer location once the surface settles.
private struct InteractiveCardHoverGate: ViewModifier {
  let isScrolling: Bool
  @Binding var isHovered: Bool

  @ViewBuilder
  func body(content: Content) -> some View {
    if isScrolling {
      content
    } else {
      content.onHover { isHovering in
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
    }
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

  /// Publishes the scroll phase of the receiver (which must be a ScrollView)
  /// into the `harnessIsScrolling` environment so descendants can suppress
  /// hit-test-heavy responders while the surface is in motion.
  func harnessScrollPhaseSetsHoverGate() -> some View {
    modifier(HarnessScrollPhaseHoverGateModifier())
  }
}

private struct HarnessScrollPhaseHoverGateModifier: ViewModifier {
  @State private var isScrolling = false

  func body(content: Content) -> some View {
    content
      .environment(\.harnessIsScrolling, isScrolling)
      .onScrollPhaseChange { _, newPhase in
        let nextIsScrolling = newPhase.isScrolling
        guard nextIsScrolling != isScrolling else { return }
        isScrolling = nextIsScrolling
      }
  }
}
