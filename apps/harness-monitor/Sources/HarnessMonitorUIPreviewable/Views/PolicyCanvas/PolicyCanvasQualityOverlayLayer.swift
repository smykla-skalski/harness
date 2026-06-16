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
private final class PolicyCanvasQualityOverlayView: NSView {
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

      drawDetours(warning: warning)
      drawCorridors(error: error, warning: warning)
      drawLongEdges(warning: warning)
      drawNodeDistance(warning: warning)
      drawNodeOverlaps(error: error)
      drawBodyHits(error: error)
      drawLabels(error: error, warning: warning)
      drawWrongTurns(warning: warning)
      drawCrossings(warning: warning)
      drawCrossedPorts(warning: warning)
      drawPortSpacing(error: error, warning: warning)
    }
  }

  private func drawLongEdges(warning: Color) {
    let path = NSBezierPath()
    for violation in report.longEdges {
      path.append(NSBezierPath(rect: violation.bounds))
    }
    policyCanvasStroke(path, color: warning, alpha: 0.4, lineWidth: 1, dash: [4, 4])
  }

  private func drawDetours(warning: Color) {
    let path = NSBezierPath()
    for violation in report.detours {
      path.append(policyCanvasAppKitPolylinePath(points: violation.points))
    }
    policyCanvasStroke(path, color: warning, alpha: 0.22, lineWidth: 12)
  }

  private func drawNodeDistance(warning: Color) {
    let line = NSBezierPath()
    let ticks = NSBezierPath()
    for violation in report.nodeDistance {
      appendLine(to: line, from: violation.gapStart, to: violation.gapEnd)
      for end in [violation.gapStart, violation.gapEnd] {
        appendLine(
          to: ticks,
          from: CGPoint(x: end.x, y: end.y - 6),
          to: CGPoint(x: end.x, y: end.y + 6)
        )
      }
    }
    policyCanvasStroke(line, color: warning, alpha: 0.7, lineWidth: 1.5, dash: [5, 3])
    policyCanvasStroke(ticks, color: warning, alpha: 0.7, lineWidth: 1.5)
  }

  private func drawWrongTurns(warning: Color) {
    let halo = NSBezierPath()
    let shafts = NSBezierPath()
    let heads = NSBezierPath()
    for violation in report.wrongTurns {
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

  private func drawNodeOverlaps(error: Color) {
    let path = NSBezierPath()
    for violation in report.nodeOverlaps {
      path.append(NSBezierPath(rect: violation.intersection))
    }
    policyCanvasFill(path, color: error, alpha: 0.25)
    policyCanvasStroke(path, color: error, lineWidth: 1.5)
  }

  private func drawBodyHits(error: Color) {
    let path = NSBezierPath()
    for violation in report.bodyHits {
      path.append(roundedRect(violation.frame, radius: 4))
    }
    policyCanvasStroke(path, color: error, lineWidth: 2)
  }

  private func drawCorridors(error: Color, warning: Color) {
    let collinear = NSBezierPath()
    let parallel = NSBezierPath()
    for violation in report.corridors {
      let target = violation.kind == .collinear ? collinear : parallel
      appendLine(to: target, from: violation.overlapStart, to: violation.overlapEnd)
    }
    policyCanvasStroke(parallel, color: warning, alpha: 0.28, lineWidth: 10)
    policyCanvasStroke(collinear, color: error, alpha: 0.32, lineWidth: 10)
  }

  private func drawLabels(error: Color, warning: Color) {
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

  private func drawCrossings(warning: Color) {
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
      if violation.sharesEndpointNode {
        shared.append(NSBezierPath(ovalIn: rect))
      } else {
        independent.append(NSBezierPath(ovalIn: rect))
      }
    }
    policyCanvasStroke(shared, color: warning, alpha: 0.85, lineWidth: 1.5)
    policyCanvasFill(independent, color: warning, alpha: 0.95)
  }

  private func drawCrossedPorts(warning: Color) {
    let connectors = NSBezierPath()
    let rings = NSBezierPath()
    let crosses = NSBezierPath()
    let radius: CGFloat = 5
    for violation in report.crossedPorts {
      appendLine(to: connectors, from: violation.pointA, to: violation.pointB)
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
      let mid = CGPoint(
        x: (violation.pointA.x + violation.pointB.x) / 2,
        y: (violation.pointA.y + violation.pointB.y) / 2
      )
      let arm: CGFloat = 5
      appendLine(
        to: crosses,
        from: CGPoint(x: mid.x - arm, y: mid.y - arm),
        to: CGPoint(x: mid.x + arm, y: mid.y + arm)
      )
      appendLine(
        to: crosses,
        from: CGPoint(x: mid.x - arm, y: mid.y + arm),
        to: CGPoint(x: mid.x + arm, y: mid.y - arm)
      )
    }
    policyCanvasStroke(connectors, color: warning, alpha: 0.45, lineWidth: 1, dash: [3, 3])
    policyCanvasStroke(rings, color: warning, lineWidth: 1.5)
    policyCanvasStroke(crosses, color: warning, lineWidth: 2)
  }

  private func drawPortSpacing(error: Color, warning: Color) {
    let errorRings = NSBezierPath()
    let warningRings = NSBezierPath()
    let detachedConnectors = NSBezierPath()
    let unevenArrows = NSBezierPath()
    let unevenGhosts = NSBezierPath()
    for violation in report.portSpacing {
      switch violation.kind {
      case .overlap:
        errorRings.append(portRing(violation.point))
        violation.otherPoint.map { errorRings.append(portRing($0)) }
      case .tooClose:
        warningRings.append(portRing(violation.point))
        violation.otherPoint.map { warningRings.append(portRing($0)) }
      case .detached:
        errorRings.append(portRing(violation.point))
        if let other = violation.otherPoint {
          appendLine(to: detachedConnectors, from: violation.point, to: other)
        }
      case .uneven:
        warningRings.append(portRing(violation.point))
        if let ideal = violation.otherPoint {
          unevenArrows.append(portNudge(from: violation.point, to: ideal))
          unevenGhosts.append(NSBezierPath(ovalIn: portRingRect(ideal)))
        }
      }
    }
    policyCanvasStroke(detachedConnectors, color: error, alpha: 0.5, lineWidth: 1)
    policyCanvasStroke(unevenArrows, color: warning, alpha: 0.7, lineWidth: 1, dash: [3, 2])
    policyCanvasStroke(unevenGhosts, color: warning, alpha: 0.6, lineWidth: 1, dash: [2, 2])
    policyCanvasStroke(warningRings, color: warning, lineWidth: 1.5)
    policyCanvasStroke(errorRings, color: error, lineWidth: 1.5)
  }

  private func roundedRect(_ rect: CGRect, radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
  }

  private func appendLine(to path: NSBezierPath, from start: CGPoint, to end: CGPoint) {
    path.move(to: start)
    path.line(to: end)
  }

  private func portRingRect(_ point: CGPoint, radius: CGFloat = 6) -> CGRect {
    CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
  }

  private func portRing(_ point: CGPoint) -> NSBezierPath {
    NSBezierPath(ovalIn: portRingRect(point))
  }

  private func portNudge(from start: CGPoint, to end: CGPoint) -> NSBezierPath {
    let path = NSBezierPath()
    appendLine(to: path, from: start, to: end)
    path.append(policyCanvasAppKitArrowHead(from: start, to: end, size: 4))
    return path
  }
}
