import HarnessMonitorPolicyCanvasAlgorithms
import SwiftUI

/// In-flight rubber-band edge layer. Renders a single Bézier curve from the
/// source port anchor to the live cursor position while the user drags from
/// an output port. Sits between the edge layer and the node layer in the
/// workspace stack so the curve passes under the source node card but over
/// committed edges, mirroring the order Norman calls the "central affordance
/// of the surface".
///
/// The path matches the resting edge style: same stroke width, same accent
/// color sourced from the originating node's kind. The curve is decorative
/// — source and target ports carry their own VoiceOver labels, and the
/// shape is `allowsHitTesting(false)` — so it is always hidden from AT.
/// Reduce-motion goes through `policyCanvasReducedMotion` (with system
/// fallback) for parity with the rest of the canvas; the layer reserves the
/// gate for a future animated drop, even though the in-flight curve never
/// animates implicitly.
struct PolicyCanvasRubberBandLayer: View {
  let viewModel: PolicyCanvasViewModel
  @Environment(\.policyCanvasReducedMotion)
  private var canvasReducedMotion
  @Environment(\.accessibilityReduceMotion)
  private var systemReduceMotion

  /// Resolved reduce-motion bit. Prefer the canvas-scoped override (set by
  /// `PolicyCanvasView` from the system flag, or by tests via the
  /// environment-override hook) and fall back to the system flag when nil.
  private var reducedMotion: Bool {
    canvasReducedMotion ?? systemReduceMotion
  }

  var body: some View {
    if let preview = viewModel.pendingEdgePreview {
      PolicyCanvasRubberBandShape(
        source: preview.sourceAnchor,
        target: preview.cursor
      )
      .stroke(
        accentColor(for: preview),
        style: StrokeStyle(lineWidth: 2.0, lineCap: .round, lineJoin: .round, dash: [5, 4])
      )
      .opacity(0.58)
      .transaction { transaction in
        // The endpoint moves on every cursor update; an implicit animation
        // would lag behind the gesture and feel rubbery. Reduce-motion still
        // gets the same no-animation path (the curve is geometrically the
        // same), the difference is only that a future animated drop won't
        // run when reduce-motion is on.
        transaction.animation = nil
      }
      // Always hidden from AT. The rubber-band is a decorative in-flight
      // affordance; the source/target ports already expose their own
      // VoiceOver labels via their respective `PolicyCanvasPortColumn`
      // rendering. The resolved `reducedMotion` flag stays available for the
      // future animated-drop transition the `transaction.animation = nil`
      // gate reserves.
      .accessibilityHidden(true)
      .allowsHitTesting(false)
    }
  }

  private func accentColor(for preview: PolicyCanvasPendingEdgePreview) -> Color {
    viewModel.node(preview.source.nodeID)?.kind.accentColor ?? PolicyCanvasVisualStyle.activeTint
  }
}

/// Cubic Bézier from `source` to `target` with horizontal control handles.
/// Control offset is proportional to the horizontal distance, clamped so a
/// near-vertical drop still produces a visible curve. Matches the visual
/// language of committed edge segments without using the orthogonal routing
/// machinery (which is overkill for an ephemeral in-flight preview).
struct PolicyCanvasRubberBandShape: Shape {
  let source: CGPoint
  let target: CGPoint

  func path(in rect: CGRect) -> Path {
    var path = Path()
    path.move(to: source)
    let offset = controlOffset(source: source, target: target)
    path.addCurve(
      to: target,
      control1: CGPoint(x: source.x + offset, y: source.y),
      control2: CGPoint(x: target.x - offset, y: target.y)
    )
    return path
  }

  /// Half the horizontal span, clamped between 48 and 220pt. The lower bound
  /// keeps near-vertical drops curved enough to read as a Bézier (not a
  /// straight line); the upper bound prevents long horizontal drags from
  /// developing a wild overshoot.
  private func controlOffset(source: CGPoint, target: CGPoint) -> CGFloat {
    let horizontal = target.x - source.x
    let magnitude = max(48, min(220, abs(horizontal) * 0.5))
    return horizontal >= 0 ? magnitude : -magnitude
  }
}
