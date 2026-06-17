import AppKit
import HarnessMonitorPolicyCanvasAlgorithms
import SwiftUI

@MainActor
func policyCanvasApplyTransparentDrawingBacking(to view: NSView) {
  view.wantsLayer = true
  view.layer?.backgroundColor = NSColor.clear.cgColor
  view.layer?.isOpaque = false
}

func policyCanvasResolvedNSColor(_ color: Color, alpha: CGFloat? = nil) -> NSColor {
  let nsColor = NSColor(color)
  let resolved = nsColor.usingColorSpace(.deviceRGB) ?? nsColor
  guard let alpha else {
    return resolved
  }
  return resolved.withAlphaComponent(alpha)
}

func policyCanvasAppKitEdgePath(
  points: [CGPoint],
  cornerRadius: CGFloat = 7
) -> NSBezierPath? {
  guard let first = points.first else {
    return nil
  }
  let path = NSBezierPath()
  path.move(to: first)
  guard points.count >= 3 else {
    for point in points.dropFirst() {
      path.line(to: point)
    }
    policyCanvasConfigureLinePath(path)
    return path
  }
  for index in 1..<points.count - 1 {
    let previous = points[index - 1]
    let current = points[index]
    let next = points[index + 1]
    let inUnit = (current - previous).normalized
    let outUnit = (next - current).normalized
    let radius = min(
      cornerRadius,
      min((current - previous).length, (next - current).length) / 2
    )
    let from = current - inUnit * radius
    let to = current + outUnit * radius
    path.line(to: from)
    path.curve(
      to: to,
      controlPoint1: from + (current - from) * (2 / 3),
      controlPoint2: to + (current - to) * (2 / 3)
    )
  }
  if let last = points.last {
    path.line(to: last)
  }
  policyCanvasConfigureLinePath(path)
  return path
}

func policyCanvasAppKitPolylinePath(points: [CGPoint]) -> NSBezierPath {
  let path = NSBezierPath()
  guard let first = points.first else {
    return path
  }
  path.move(to: first)
  for point in points.dropFirst() {
    path.line(to: point)
  }
  policyCanvasConfigureLinePath(path)
  return path
}

func policyCanvasAppKitArrowHead(
  from start: CGPoint,
  to end: CGPoint,
  size: CGFloat
) -> NSBezierPath {
  let path = NSBezierPath()
  if abs(end.x - start.x) >= abs(end.y - start.y) {
    let direction: CGFloat = end.x >= start.x ? 1 : -1
    path.move(to: end)
    path.line(to: CGPoint(x: end.x - direction * size, y: end.y - size * 0.7))
    path.line(to: CGPoint(x: end.x - direction * size, y: end.y + size * 0.7))
  } else {
    let direction: CGFloat = end.y >= start.y ? 1 : -1
    path.move(to: end)
    path.line(to: CGPoint(x: end.x - size * 0.7, y: end.y - direction * size))
    path.line(to: CGPoint(x: end.x + size * 0.7, y: end.y - direction * size))
  }
  path.close()
  return path
}

func policyCanvasStroke(
  _ path: NSBezierPath,
  color: Color,
  alpha: CGFloat? = nil,
  lineWidth: CGFloat,
  dash: [CGFloat] = []
) {
  policyCanvasResolvedNSColor(color, alpha: alpha).setStroke()
  path.lineWidth = lineWidth
  path.lineCapStyle = .round
  path.lineJoinStyle = .round
  if !dash.isEmpty {
    var dashPattern = dash
    dashPattern.withUnsafeMutableBufferPointer { buffer in
      path.setLineDash(buffer.baseAddress, count: buffer.count, phase: 0)
    }
  } else {
    path.setLineDash(nil, count: 0, phase: 0)
  }
  path.stroke()
}

func policyCanvasFill(
  _ path: NSBezierPath,
  color: Color,
  alpha: CGFloat? = nil
) {
  policyCanvasResolvedNSColor(color, alpha: alpha).setFill()
  path.fill()
}

private func policyCanvasConfigureLinePath(_ path: NSBezierPath) {
  path.lineCapStyle = .round
  path.lineJoinStyle = .round
}
