import HarnessMonitorKit
import SwiftUI

/// Hover and press wash for an expanded lane header.
///
/// One fixed gradient scaled by `intensity`, not a differently tinted gradient
/// per state: SwiftUI does not interpolate gradient stops, so re-tinting would
/// snap between hover and press instead of crossfading.
struct TaskBoardLaneHeaderFade: Equatable {
  struct Stop: Equatable {
    let location: Double
    let weight: Double
  }

  /// Relative weights from the header's top edge down. The trailing zero is the
  /// whole point of the effect: with no bottom edge there is no shape left to
  /// read as a card laid on top of the lane.
  static let stops = [
    Stop(location: 0, weight: 1),
    Stop(location: 0.55, weight: 0.34),
    Stop(location: 1, weight: 0),
  ]

  /// Ceiling on the top-edge opacity, so even the loudest accessibility
  /// combination stays a wash over the lane surface instead of a band of flat
  /// lane color.
  static let maximumIntensity = 0.75

  /// Opacity at the top edge. Every other stop is this scaled by its weight.
  let intensity: Double

  var isActive: Bool { intensity > 0 }

  init(
    isHovered: Bool,
    isPressed: Bool,
    reduceTransparency: Bool,
    increasesContrast: Bool
  ) {
    let base: Double =
      if isPressed {
        0.45
      } else if isHovered {
        0.3
      } else {
        0
      }
    // The header no longer draws an outline to fall back on, so a flattened or
    // high-contrast appearance raises the wash rather than losing the feedback.
    // The boosts stay small because the base already carries the effect; a
    // louder multiplier here would only push both settings onto the ceiling,
    // where appearances that should differ collapse into one wash.
    let boost = (reduceTransparency ? 1.25 : 1) * (increasesContrast ? 1.15 : 1)
    intensity = min(Self.maximumIntensity, base * boost)
  }

  func gradient(for color: Color) -> LinearGradient {
    LinearGradient(
      stops: Self.stops.map {
        Gradient.Stop(color: color.opacity($0.weight), location: $0.location)
      },
      startPoint: .top,
      endPoint: .bottom
    )
  }

  static func hoverAnimation(reduceMotion: Bool) -> Animation? {
    reduceMotion ? nil : .easeOut(duration: 0.12)
  }

  static func pressAnimation(reduceMotion: Bool) -> Animation? {
    reduceMotion ? nil : .easeOut(duration: 0.08)
  }
}

/// The wash itself, separated from the state plumbing so a preview can render
/// hover and press without a live pointer.
struct TaskBoardLaneHeaderFadeLayer: View {
  let color: Color
  let cornerRadius: CGFloat
  let fade: TaskBoardLaneHeaderFade

  var body: some View {
    TaskBoardLaneTopRoundedShape(cornerRadius: cornerRadius)
      .fill(fade.gradient(for: color))
      .opacity(fade.intensity)
      .allowsHitTesting(false)
      .accessibilityHidden(true)
  }
}

private struct TaskBoardLaneHeaderFadeModifier: ViewModifier {
  let lane: TaskBoardInboxLane
  let cornerRadius: CGFloat
  @State private var isHovered = false
  @GestureState private var isPressed = false
  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion
  @Environment(\.accessibilityReduceTransparency)
  private var reduceTransparency
  @Environment(\.colorSchemeContrast)
  private var colorSchemeContrast
  @Environment(\.taskBoardLaneAppearance)
  private var laneAppearance

  private var fade: TaskBoardLaneHeaderFade {
    TaskBoardLaneHeaderFade(
      isHovered: isHovered,
      isPressed: isPressed,
      reduceTransparency: reduceTransparency,
      increasesContrast: colorSchemeContrast == .increased
    )
  }

  func body(content: Content) -> some View {
    content
      .background {
        TaskBoardLaneHeaderFadeLayer(
          color: taskBoardLaneColor(for: lane, appearance: laneAppearance),
          cornerRadius: cornerRadius,
          fade: fade
        )
      }
      .onHover { hovering in
        isHovered = hovering
      }
      .simultaneousGesture(pressGesture)
      .animation(
        TaskBoardLaneHeaderFade.hoverAnimation(reduceMotion: reduceMotion), value: isHovered
      )
      .animation(
        TaskBoardLaneHeaderFade.pressAnimation(reduceMotion: reduceMotion), value: isPressed)
  }

  private var pressGesture: some Gesture {
    DragGesture(minimumDistance: 0)
      .updating($isPressed) { _, state, _ in
        state = true
      }
  }
}

extension View {
  /// Expanded-lane header feedback: a wash anchored to the lane's top corners
  /// that fades out before the header meets the lane body. The collapsed rail
  /// keeps `taskBoardLaneToggleFeedback` instead, where a bounded shape is the
  /// whole control.
  func taskBoardLaneHeaderFade(
    lane: TaskBoardInboxLane,
    cornerRadius: CGFloat
  ) -> some View {
    modifier(TaskBoardLaneHeaderFadeModifier(lane: lane, cornerRadius: cornerRadius))
  }
}
