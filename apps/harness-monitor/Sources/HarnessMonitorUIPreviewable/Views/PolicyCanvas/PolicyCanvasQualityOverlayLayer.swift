import HarnessMonitorPolicyCanvasAlgorithms
import SwiftUI

/// Content-space overlay that marks every graph-quality violation directly on the
/// canvas, in the same coordinate space as the routes, so a developer can see
/// exactly where a port collision, a reused corridor, a crossing, or a pierced
/// body sits. Lab-only: driven by `viewModel.qualityInspectionReport`, which the
/// metrics toggle populates. A single `Canvas` batches all markers by color, so
/// even the dense extreme samples stay a handful of draw calls, and it redraws
/// only when the report changes - never per scroll frame (the scroll view
/// transforms the rendered layer instead of re-running the renderer).
struct PolicyCanvasQualityOverlayLayer: View {
  let report: PolicyCanvasGraphQualityReport

  var body: some View {
    Canvas { context, _ in
      let error = PolicyCanvasVisualStyle.blockedTint
      let warning = PolicyCanvasVisualStyle.warningTint

      drawLongEdges(into: &context, warning: warning)
      drawNodeOverlaps(into: &context, error: error)
      drawBodyHits(into: &context, error: error)
      drawCorridors(into: &context, error: error, warning: warning)
      drawLabels(into: &context, error: error, warning: warning)
      drawCrossings(into: &context, warning: warning)
      drawPortSpacing(into: &context, error: error, warning: warning)
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }

  /// Bounding box of each cross-canvas long edge, dashed and faint (background).
  private func drawLongEdges(into context: inout GraphicsContext, warning: Color) {
    var path = Path()
    for violation in report.longEdges {
      path.addRect(violation.bounds)
    }
    context.stroke(
      path,
      with: .color(warning.opacity(0.4)),
      style: StrokeStyle(lineWidth: 1, dash: [4, 4])
    )
  }

  /// Filled intersection of any two overlapping node bodies (should never occur).
  private func drawNodeOverlaps(into context: inout GraphicsContext, error: Color) {
    var path = Path()
    for violation in report.nodeOverlaps {
      path.addRect(violation.intersection)
    }
    context.fill(path, with: .color(error.opacity(0.25)))
    context.stroke(path, with: .color(error), lineWidth: 1.5)
  }

  /// Outline of each foreign node or group-title band a route runs through.
  private func drawBodyHits(into context: inout GraphicsContext, error: Color) {
    var path = Path()
    for violation in report.bodyHits {
      path.addRoundedRect(in: violation.frame, cornerSize: CGSize(width: 4, height: 4))
    }
    context.stroke(path, with: .color(error), lineWidth: 2)
  }

  /// Thick stroke along each shared corridor: collinear reuse is an error, a
  /// parallel-too-close pair is a warning.
  private func drawCorridors(into context: inout GraphicsContext, error: Color, warning: Color) {
    var collinear = Path()
    var parallel = Path()
    for violation in report.corridors {
      var segment = Path()
      segment.move(to: violation.overlapStart)
      segment.addLine(to: violation.overlapEnd)
      if violation.kind == .collinear {
        collinear.addPath(segment)
      } else {
        parallel.addPath(segment)
      }
    }
    let style = StrokeStyle(lineWidth: 4, lineCap: .round)
    context.stroke(parallel, with: .color(warning.opacity(0.5)), style: style)
    context.stroke(collinear, with: .color(error.opacity(0.55)), style: style)
  }

  /// Outline of each label that overlaps another, sits on a body, or drifted.
  private func drawLabels(into context: inout GraphicsContext, error: Color, warning: Color) {
    var errorPath = Path()
    var warningPath = Path()
    for violation in report.labels {
      if violation.severity == .error {
        errorPath.addRect(violation.frame)
      } else {
        warningPath.addRect(violation.frame)
      }
    }
    context.stroke(warningPath, with: .color(warning.opacity(0.7)), lineWidth: 1)
    context.stroke(errorPath, with: .color(error.opacity(0.7)), lineWidth: 1)
  }

  /// A dot at each proper crossing: independent crossings (no shared endpoint)
  /// pop; endpoint-sharing crossings stay faint since they are often unavoidable.
  private func drawCrossings(into context: inout GraphicsContext, warning: Color) {
    var independent = Path()
    var shared = Path()
    for violation in report.crossings {
      let radius: CGFloat = violation.sharesEndpointNode ? 2 : 3.5
      let rect = CGRect(
        x: violation.point.x - radius,
        y: violation.point.y - radius,
        width: radius * 2,
        height: radius * 2
      )
      if violation.sharesEndpointNode {
        shared.addEllipse(in: rect)
      } else {
        independent.addEllipse(in: rect)
      }
    }
    context.fill(shared, with: .color(warning.opacity(0.3)))
    context.fill(independent, with: .color(warning.opacity(0.85)))
  }

  /// A ring at each mis-spaced port marker, plus a connector to its crowding
  /// neighbor when there is one.
  private func drawPortSpacing(into context: inout GraphicsContext, error: Color, warning: Color) {
    var errorRings = Path()
    var warningRings = Path()
    var connectors = Path()
    for violation in report.portSpacing {
      let radius: CGFloat = 6
      let rect = CGRect(
        x: violation.point.x - radius,
        y: violation.point.y - radius,
        width: radius * 2,
        height: radius * 2
      )
      if violation.severity == .error {
        errorRings.addEllipse(in: rect)
      } else {
        warningRings.addEllipse(in: rect)
      }
      if let other = violation.otherPoint {
        connectors.move(to: violation.point)
        connectors.addLine(to: other)
      }
    }
    context.stroke(connectors, with: .color(error.opacity(0.5)), lineWidth: 1)
    context.stroke(warningRings, with: .color(warning), lineWidth: 1.5)
    context.stroke(errorRings, with: .color(error), lineWidth: 1.5)
  }
}
