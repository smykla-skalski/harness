import AppKit
import HarnessMonitorPolicyCanvasAlgorithms

private let qualityOverlayDirtyPadding: CGFloat = 18

extension PolicyCanvasQualityOverlayView {
  func qualityMarkIntersectsDirtyRect(
    _ markRect: CGRect,
    dirtyRect: CGRect,
    padding: CGFloat? = nil
  ) -> Bool {
    guard !markRect.isNull else {
      return false
    }
    let resolvedPadding = padding ?? qualityOverlayDirtyPadding
    let padded = markRect.standardized.insetBy(
      dx: -resolvedPadding,
      dy: -resolvedPadding
    )
    return padded.intersects(dirtyRect)
  }

  func lineDirtyRect(
    from start: CGPoint,
    to end: CGPoint,
    padding: CGFloat
  ) -> CGRect {
    CGRect(
      x: min(start.x, end.x),
      y: min(start.y, end.y),
      width: abs(start.x - end.x),
      height: abs(start.y - end.y)
    )
    .standardized
    .insetBy(dx: -padding, dy: -padding)
  }

  func portSpacingDirtyRect(
    for violation: PolicyCanvasPortSpacingViolation
  ) -> CGRect {
    var rect = portRingRect(violation.point)
    if let otherPoint = violation.otherPoint {
      rect = rect.union(portRingRect(otherPoint))
    }
    return rect.insetBy(dx: -6, dy: -6)
  }

  func roundedRect(_ rect: CGRect, radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
  }

  func appendLine(to path: NSBezierPath, from start: CGPoint, to end: CGPoint) {
    path.move(to: start)
    path.line(to: end)
  }

  func portRingRect(_ point: CGPoint, radius: CGFloat = 6) -> CGRect {
    CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
  }

  func portRing(_ point: CGPoint) -> NSBezierPath {
    NSBezierPath(ovalIn: portRingRect(point))
  }

  func portNudge(from start: CGPoint, to end: CGPoint) -> NSBezierPath {
    let path = NSBezierPath()
    appendLine(to: path, from: start, to: end)
    path.append(policyCanvasAppKitArrowHead(from: start, to: end, size: 4))
    return path
  }
}
