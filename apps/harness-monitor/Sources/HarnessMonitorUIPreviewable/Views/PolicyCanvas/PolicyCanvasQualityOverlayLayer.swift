import HarnessMonitorPolicyCanvasAlgorithms
import SwiftUI

/// Live entry point for the quality overlay. Reads `qualityInspectionReport` off
/// the view model in its own body - the same direct-read pattern the hover layer
/// uses - so it re-renders whenever the report changes, even inside the hosted
/// `NSHostingView` canvas where a value captured by the parent's `if let` would
/// go stale across a variant switch or an overlay toggle. Renders nothing when
/// the lab metrics overlay is off, so it is safe to mount always.
struct PolicyCanvasQualityOverlayLayer: View {
  let viewModel: PolicyCanvasViewModel

  var body: some View {
    if let report = viewModel.qualityInspectionReport {
      PolicyCanvasQualityOverlayMarks(report: report)
    }
  }
}

/// Content-space overlay that marks every graph-quality violation directly on the
/// canvas, in the same coordinate space as the routes, so a developer can see
/// exactly where a port collision, a reused corridor, a crossing, or a pierced
/// body sits. Lab-only. A single `Canvas` batches all markers by color, so even
/// the dense extreme samples stay a handful of draw calls, and it redraws only
/// when the report changes - never per scroll frame (the scroll view transforms
/// the rendered layer instead of re-running the renderer).
struct PolicyCanvasQualityOverlayMarks: View {
  let report: PolicyCanvasGraphQualityReport

  var body: some View {
    Canvas { context, _ in
      let error = PolicyCanvasVisualStyle.blockedTint
      let warning = PolicyCanvasVisualStyle.warningTint

      drawDetours(into: &context, warning: warning)
      drawCorridors(into: &context, error: error, warning: warning)
      drawLongEdges(into: &context, warning: warning)
      drawNodeDistance(into: &context, warning: warning)
      drawNodeOverlaps(into: &context, error: error)
      drawBodyHits(into: &context, error: error)
      drawLabels(into: &context, error: error, warning: warning)
      drawWrongTurns(into: &context, warning: warning)
      drawCrossings(into: &context, warning: warning)
      drawCrossedPorts(into: &context, warning: warning)
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

  /// A wide, low-opacity halo over each detouring route. The halo overflows the
  /// wire so the colored route stays visible through the highlight instead of
  /// being painted over.
  private func drawDetours(into context: inout GraphicsContext, warning: Color) {
    var path = Path()
    for violation in report.detours {
      guard let first = violation.points.first else {
        continue
      }
      path.move(to: first)
      for point in violation.points.dropFirst() {
        path.addLine(to: point)
      }
    }
    context.stroke(
      path,
      with: .color(warning.opacity(0.22)),
      style: StrokeStyle(lineWidth: 12, lineCap: .round, lineJoin: .round)
    )
  }

  /// A dashed dimension line with end ticks spanning the gap between two
  /// connected nodes the layout placed too far apart horizontally.
  private func drawNodeDistance(into context: inout GraphicsContext, warning: Color) {
    var line = Path()
    var ticks = Path()
    for violation in report.nodeDistance {
      line.move(to: violation.gapStart)
      line.addLine(to: violation.gapEnd)
      for end in [violation.gapStart, violation.gapEnd] {
        ticks.move(to: CGPoint(x: end.x, y: end.y - 6))
        ticks.addLine(to: CGPoint(x: end.x, y: end.y + 6))
      }
    }
    context.stroke(
      line,
      with: .color(warning.opacity(0.7)),
      style: StrokeStyle(lineWidth: 1.5, dash: [5, 3])
    )
    context.stroke(ticks, with: .color(warning.opacity(0.7)), lineWidth: 1.5)
  }

  /// An arrow along each backtracking segment, pointing the way the wire wrongly
  /// doubles back, over a faint wide halo so the reversed wire stays visible.
  private func drawWrongTurns(into context: inout GraphicsContext, warning: Color) {
    var halo = Path()
    var shafts = Path()
    var heads = Path()
    for violation in report.wrongTurns {
      halo.move(to: violation.point)
      halo.addLine(to: violation.returnPoint)
      shafts.move(to: violation.point)
      shafts.addLine(to: violation.returnPoint)
      heads.addPath(policyCanvasArrowHead(from: violation.point, to: violation.returnPoint, size: 6))
    }
    context.stroke(
      halo,
      with: .color(warning.opacity(0.2)),
      style: StrokeStyle(lineWidth: 9, lineCap: .round)
    )
    context.stroke(shafts, with: .color(warning.opacity(0.75)), lineWidth: 1.5)
    context.fill(heads, with: .color(warning.opacity(0.9)))
  }

  /// A small filled triangle at `end`, pointing along the `start` to `end`
  /// direction. The segment is axis-aligned, so the arrow points purely left,
  /// right, up, or down.
  private func policyCanvasArrowHead(from start: CGPoint, to end: CGPoint, size: CGFloat) -> Path {
    var path = Path()
    if abs(end.x - start.x) >= abs(end.y - start.y) {
      let direction: CGFloat = end.x >= start.x ? 1 : -1
      path.move(to: end)
      path.addLine(to: CGPoint(x: end.x - direction * size, y: end.y - size * 0.7))
      path.addLine(to: CGPoint(x: end.x - direction * size, y: end.y + size * 0.7))
    } else {
      let direction: CGFloat = end.y >= start.y ? 1 : -1
      path.move(to: end)
      path.addLine(to: CGPoint(x: end.x - size * 0.7, y: end.y - direction * size))
      path.addLine(to: CGPoint(x: end.x + size * 0.7, y: end.y - direction * size))
    }
    path.closeSubpath()
    return path
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
    let style = StrokeStyle(lineWidth: 10, lineCap: .round)
    context.stroke(parallel, with: .color(warning.opacity(0.28)), style: style)
    context.stroke(collinear, with: .color(error.opacity(0.32)), style: style)
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

  /// The two ports of each crossed pair, ringed and joined by a dashed connector,
  /// with an X at the midpoint - the wires attach in the wrong order and would
  /// untangle if the ports were swapped.
  private func drawCrossedPorts(into context: inout GraphicsContext, warning: Color) {
    var connectors = Path()
    var rings = Path()
    var crosses = Path()
    let radius: CGFloat = 5
    for violation in report.crossedPorts {
      connectors.move(to: violation.pointA)
      connectors.addLine(to: violation.pointB)
      for point in [violation.pointA, violation.pointB] {
        rings.addEllipse(
          in: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
        )
      }
      let mid = CGPoint(
        x: (violation.pointA.x + violation.pointB.x) / 2,
        y: (violation.pointA.y + violation.pointB.y) / 2
      )
      let arm: CGFloat = 5
      crosses.move(to: CGPoint(x: mid.x - arm, y: mid.y - arm))
      crosses.addLine(to: CGPoint(x: mid.x + arm, y: mid.y + arm))
      crosses.move(to: CGPoint(x: mid.x - arm, y: mid.y + arm))
      crosses.addLine(to: CGPoint(x: mid.x + arm, y: mid.y - arm))
    }
    context.stroke(
      connectors,
      with: .color(warning.opacity(0.45)),
      style: StrokeStyle(lineWidth: 1, dash: [3, 3])
    )
    context.stroke(rings, with: .color(warning), lineWidth: 1.5)
    context.stroke(
      crosses,
      with: .color(warning),
      style: StrokeStyle(lineWidth: 2, lineCap: .round)
    )
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
