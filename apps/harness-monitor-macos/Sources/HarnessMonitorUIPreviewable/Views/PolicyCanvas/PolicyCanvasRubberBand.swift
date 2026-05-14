import SwiftUI

/// In-flight rubber-band edge layer. Renders a single Bézier curve from the
/// source port anchor to the live cursor position while the user drags from
/// an output port. Sits between the edge layer and the node layer in the
/// workspace stack so the curve passes under the source node card but over
/// committed edges, mirroring the order Norman calls the "central affordance
/// of the surface".
///
/// The path matches the resting edge style: same stroke width, same accent
/// color sourced from the originating node's kind. Animations are skipped
/// when `accessibilityReduceMotion` is on; otherwise the curve smoothly
/// follows the cursor without a transition (the cursor itself drives the
/// changing endpoint, not an implicit animation).
struct PolicyCanvasRubberBandLayer: View {
  let viewModel: PolicyCanvasViewModel
  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion

  var body: some View {
    if let preview = viewModel.pendingEdgePreview {
      PolicyCanvasRubberBandShape(
        source: preview.sourceAnchor,
        target: preview.cursor
      )
      .stroke(
        accentColor(for: preview),
        style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round, dash: [5, 4])
      )
      .opacity(0.86)
      .transaction { transaction in
        // The endpoint moves on every cursor update; an implicit animation
        // would lag behind the gesture and feel rubbery. Reduce-motion still
        // gets the same no-animation path (the curve is geometrically the
        // same), the difference is only that a future animated drop won't
        // run when reduce-motion is on.
        transaction.animation = nil
      }
      .accessibilityHidden(reduceMotion)
      .allowsHitTesting(false)
    }
  }

  private func accentColor(for preview: PolicyCanvasPendingEdgePreview) -> Color {
    viewModel.node(preview.source.nodeID)?.kind.accentColor ?? Color.cyan
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
