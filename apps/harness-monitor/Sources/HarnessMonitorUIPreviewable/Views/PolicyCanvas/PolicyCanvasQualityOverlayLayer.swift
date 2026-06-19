import AppKit
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
/// body sits. Lab-only. Uses a native drawing surface because full-document
/// SwiftUI `Canvas` layers can disappear on very large hosted documents.
struct PolicyCanvasQualityOverlayMarks: View {
  let report: PolicyCanvasGraphQualityReport

  var body: some View {
    PolicyCanvasQualityOverlaySurface(report: report)
      .allowsHitTesting(false)
      .accessibilityHidden(true)
  }
}

private struct PolicyCanvasQualityOverlaySurface: NSViewRepresentable {
  let report: PolicyCanvasGraphQualityReport

  func makeNSView(context: Context) -> PolicyCanvasQualityOverlayView {
    PolicyCanvasQualityOverlayView()
  }

  func updateNSView(_ nsView: PolicyCanvasQualityOverlayView, context: Context) {
    nsView.report = report
  }
}

@MainActor
final class PolicyCanvasQualityOverlayView: NSView {
  var report = PolicyCanvasGraphQualityReport.empty {
    didSet {
      guard report != oldValue else {
        return
      }
      needsDisplay = true
    }
  }

  override var isFlipped: Bool { true }
  override var isOpaque: Bool { false }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    policyCanvasApplyTransparentDrawingBacking(to: self)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    nil
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      let error = PolicyCanvasVisualStyle.blockedTint
      let warning = PolicyCanvasVisualStyle.warningTint

      drawDetours(warning: warning, dirtyRect: dirtyRect)
      drawRouteSegments(warning: warning, dirtyRect: dirtyRect)
      drawCorridors(error: error, warning: warning, dirtyRect: dirtyRect)
      drawLongEdges(warning: warning, dirtyRect: dirtyRect)
      drawNodeDistance(warning: warning, dirtyRect: dirtyRect)
      drawNodeOverlaps(error: error, dirtyRect: dirtyRect)
      drawBodyHits(error: error, dirtyRect: dirtyRect)
      drawLabels(error: error, warning: warning, dirtyRect: dirtyRect)
      drawWrongTurns(warning: warning, dirtyRect: dirtyRect)
      drawCrossings(warning: warning, dirtyRect: dirtyRect)
      drawCrossedPorts(warning: warning, dirtyRect: dirtyRect)
      drawPortSpacing(error: error, warning: warning, dirtyRect: dirtyRect)
    }
  }

  private func drawLongEdges(warning: Color, dirtyRect: CGRect) {
    let path = NSBezierPath()
    for violation in report.longEdges {
      guard qualityMarkIntersectsDirtyRect(violation.bounds, dirtyRect: dirtyRect) else {
        continue
      }
      path.append(NSBezierPath(rect: violation.bounds))
    }
    policyCanvasStroke(path, color: warning, alpha: 0.4, lineWidth: 1, dash: [4, 4])
  }

  private func drawDetours(warning: Color, dirtyRect: CGRect) {
    let path = NSBezierPath()
    for violation in report.detours {
      guard qualityMarkIntersectsDirtyRect(violation.bounds, dirtyRect: dirtyRect) else {
        continue
      }
      path.append(policyCanvasAppKitPolylinePath(points: violation.points))
    }
    policyCanvasStroke(path, color: warning, alpha: 0.22, lineWidth: 12)
  }

  private func drawRouteSegments(warning: Color, dirtyRect: CGRect) {
    let path = NSBezierPath()
    for violation in report.routeSegments {
      let markRect = lineDirtyRect(from: violation.start, to: violation.end, padding: 10)
      guard
        qualityMarkIntersectsDirtyRect(
          markRect,
          dirtyRect: dirtyRect,
          padding: 0
        )
      else {
        continue
      }
      appendLine(to: path, from: violation.start, to: violation.end)
    }
    policyCanvasStroke(path, color: warning, alpha: 0.34, lineWidth: 10)
  }

  private func drawNodeDistance(warning: Color, dirtyRect: CGRect) {
    let line = NSBezierPath()
    let ticks = NSBezierPath()
    for violation in report.nodeDistance {
      // The caps stretch off the line to the nodes, so the cull rect has to span
      // them too, not just the horizontal bar.
      let markRect = lineDirtyRect(from: violation.gapStart, to: violation.gapEnd, padding: 8)
        .union(lineDirtyRect(from: violation.gapStart, to: violation.gapStartCap, padding: 8))
        .union(lineDirtyRect(from: violation.gapEnd, to: violation.gapEndCap, padding: 8))
      guard
        qualityMarkIntersectsDirtyRect(
          markRect,
          dirtyRect: dirtyRect,
          padding: 0
        )
      else {
        continue
      }
      appendLine(to: line, from: violation.gapStart, to: violation.gapEnd)
      for (end, cap) in [
        (violation.gapStart, violation.gapStartCap),
        (violation.gapEnd, violation.gapEndCap),
      ] {
        // Boundary tick at the measured edge, plus the cap stretching to its node.
        appendLine(
          to: ticks,
          from: CGPoint(x: end.x, y: end.y - 6),
          to: CGPoint(x: end.x, y: end.y + 6)
        )
        appendLine(to: ticks, from: end, to: cap)
      }
    }
    policyCanvasStroke(line, color: warning, alpha: 0.7, lineWidth: 1.5, dash: [5, 3])
    policyCanvasStroke(ticks, color: warning, alpha: 0.7, lineWidth: 1.5)
  }

  private func drawWrongTurns(warning: Color, dirtyRect: CGRect) {
    let halo = NSBezierPath()
    let shafts = NSBezierPath()
    let heads = NSBezierPath()
    for violation in report.wrongTurns {
      let markRect = lineDirtyRect(
        from: violation.point,
        to: violation.returnPoint,
        padding: 10
      )
      guard
        qualityMarkIntersectsDirtyRect(
          markRect,
          dirtyRect: dirtyRect,
          padding: 0
        )
      else {
        continue
      }
      appendLine(to: halo, from: violation.point, to: violation.returnPoint)
      appendLine(to: shafts, from: violation.point, to: violation.returnPoint)
      heads.append(
        policyCanvasAppKitArrowHead(from: violation.point, to: violation.returnPoint, size: 6)
      )
    }
    policyCanvasStroke(halo, color: warning, alpha: 0.2, lineWidth: 9)
    policyCanvasStroke(shafts, color: warning, alpha: 0.75, lineWidth: 1.5)
    policyCanvasFill(heads, color: warning, alpha: 0.9)
  }

  private func drawNodeOverlaps(error: Color, dirtyRect: CGRect) {
    let path = NSBezierPath()
    for violation in report.nodeOverlaps {
      guard qualityMarkIntersectsDirtyRect(violation.intersection, dirtyRect: dirtyRect) else {
        continue
      }
      path.append(NSBezierPath(rect: violation.intersection))
    }
    policyCanvasFill(path, color: error, alpha: 0.25)
    policyCanvasStroke(path, color: error, lineWidth: 1.5)
  }

  private func drawBodyHits(error: Color, dirtyRect: CGRect) {
    let path = NSBezierPath()
    for violation in report.bodyHits {
      guard qualityMarkIntersectsDirtyRect(violation.frame, dirtyRect: dirtyRect) else {
        continue
      }
      path.append(roundedRect(violation.frame, radius: 4))
    }
    policyCanvasStroke(path, color: error, lineWidth: 2)
  }

  private func drawCorridors(error: Color, warning: Color, dirtyRect: CGRect) {
    let collinear = NSBezierPath()
    let parallel = NSBezierPath()
    for violation in report.corridors {
      let markRect = lineDirtyRect(
        from: violation.overlapStart,
        to: violation.overlapEnd,
        padding: 12
      )
      guard
        qualityMarkIntersectsDirtyRect(
          markRect,
          dirtyRect: dirtyRect,
          padding: 0
        )
      else {
        continue
      }
      let target = violation.kind == .collinear ? collinear : parallel
      appendLine(to: target, from: violation.overlapStart, to: violation.overlapEnd)
    }
    policyCanvasStroke(parallel, color: warning, alpha: 0.28, lineWidth: 10)
    policyCanvasStroke(collinear, color: error, alpha: 0.32, lineWidth: 10)
  }

  private func drawLabels(error: Color, warning: Color, dirtyRect: CGRect) {
    let radius = PolicyCanvasVisualStyle.edgeLabelCornerRadius
    let overlapOuter = NSBezierPath()
    let overlapInner = NSBezierPath()
    let onBody = NSBezierPath()
    let adrift = NSBezierPath()
    let onEdgeBox = NSBezierPath()
    let onEdgeStrike = NSBezierPath()
    let nearTurnBox = NSBezierPath()
    let nearTurnCorner = NSBezierPath()
    for violation in report.labels {
      let frame = violation.frame
      guard qualityMarkIntersectsDirtyRect(frame, dirtyRect: dirtyRect) else {
        continue
      }
      switch violation.kind {
      case .overlap:
        overlapOuter.append(roundedRect(frame, radius: radius))
        let inner = frame.insetBy(dx: 2.5, dy: 2.5)
        overlapInner.append(roundedRect(inner, radius: max(radius - 2.5, 1)))
      case .onBody:
        onBody.append(roundedRect(frame, radius: radius))
      case .farFromEdge:
        adrift.append(roundedRect(frame, radius: radius))
      case .crossesEdge:
        onEdgeBox.append(roundedRect(frame, radius: radius))
        appendLine(
          to: onEdgeStrike,
          from: CGPoint(x: frame.minX - 4, y: frame.midY),
          to: CGPoint(x: frame.maxX + 4, y: frame.midY)
        )
      case .nearTurn:
        nearTurnBox.append(roundedRect(frame, radius: radius))
        let arm: CGFloat = 6
        nearTurnCorner.move(to: CGPoint(x: frame.maxX - arm, y: frame.minY))
        nearTurnCorner.line(to: CGPoint(x: frame.maxX, y: frame.minY))
        nearTurnCorner.line(to: CGPoint(x: frame.maxX, y: frame.minY + arm))
      }
    }
    policyCanvasFill(onBody, color: error, alpha: 0.22)
    policyCanvasStroke(onBody, color: error, alpha: 0.8, lineWidth: 1)
    policyCanvasStroke(overlapOuter, color: error, alpha: 0.8, lineWidth: 1)
    policyCanvasStroke(overlapInner, color: error, alpha: 0.8, lineWidth: 1)
    policyCanvasStroke(adrift, color: warning, alpha: 0.8, lineWidth: 1, dash: [3, 2])
    policyCanvasStroke(onEdgeBox, color: warning, alpha: 0.8, lineWidth: 1)
    policyCanvasStroke(onEdgeStrike, color: warning, alpha: 0.9, lineWidth: 1.5)
    policyCanvasStroke(nearTurnBox, color: warning, alpha: 0.8, lineWidth: 1)
    policyCanvasStroke(nearTurnCorner, color: warning, alpha: 0.95, lineWidth: 2)
  }

  private func drawCrossings(warning: Color, dirtyRect: CGRect) {
    let independent = NSBezierPath()
    let shared = NSBezierPath()
    for violation in report.crossings {
      let radius: CGFloat = 3
      let rect = CGRect(
        x: violation.point.x - radius,
        y: violation.point.y - radius,
        width: radius * 2,
        height: radius * 2
      )
      guard qualityMarkIntersectsDirtyRect(rect, dirtyRect: dirtyRect) else {
        continue
      }
      if violation.sharesEndpointNode {
        shared.append(NSBezierPath(ovalIn: rect))
      } else {
        independent.append(NSBezierPath(ovalIn: rect))
      }
    }
    policyCanvasStroke(shared, color: warning, alpha: 0.85, lineWidth: 1.5)
    policyCanvasFill(independent, color: warning, alpha: 0.95)
  }

  private func drawCrossedPorts(warning: Color, dirtyRect: CGRect) {
    let connectors = NSBezierPath()
    let rings = NSBezierPath()
    let crosses = NSBezierPath()
    let radius: CGFloat = 5
    // The X is drawn at `markPoint`, computed by the measure: the midpoint between
    // two adjacent crossed ports (in the gap, between them) or, for a pair with a
    // port between them, a point nudged just off the node side so it never lands on
    // the intermediate dot or on the node body. The dashed connector runs through
    // it so the pairing stays legible.
    for violation in report.crossedPorts {
      let apex = violation.markPoint
      let markRect = lineDirtyRect(
        from: violation.pointA,
        to: violation.pointB,
        padding: PolicyCanvasLayout.portDiameter + radius + 2
      )
      guard
        qualityMarkIntersectsDirtyRect(
          markRect,
          dirtyRect: dirtyRect,
          padding: 0
        )
      else {
        continue
      }
      appendLine(to: connectors, from: violation.pointA, to: apex)
      appendLine(to: connectors, from: apex, to: violation.pointB)
      for point in [violation.pointA, violation.pointB] {
        rings.append(
          NSBezierPath(
            ovalIn: CGRect(
              x: point.x - radius,
              y: point.y - radius,
              width: radius * 2,
              height: radius * 2
            )
          )
        )
      }
      let arm: CGFloat = 5
      appendLine(
        to: crosses,
        from: CGPoint(x: apex.x - arm, y: apex.y - arm),
        to: CGPoint(x: apex.x + arm, y: apex.y + arm)
      )
      appendLine(
        to: crosses,
        from: CGPoint(x: apex.x - arm, y: apex.y + arm),
        to: CGPoint(x: apex.x + arm, y: apex.y - arm)
      )
    }
    policyCanvasStroke(connectors, color: warning, alpha: 0.45, lineWidth: 1, dash: [3, 3])
    policyCanvasStroke(rings, color: warning, lineWidth: 1.5)
    policyCanvasStroke(crosses, color: warning, lineWidth: 2)
  }

}
