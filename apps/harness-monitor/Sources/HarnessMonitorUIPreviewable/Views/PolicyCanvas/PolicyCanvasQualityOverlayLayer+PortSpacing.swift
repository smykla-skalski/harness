// Companion to PolicyCanvasQualityOverlayLayer.swift.
// Port-spacing violation drawing for PolicyCanvasQualityOverlayView.
import AppKit
import HarnessMonitorPolicyCanvasAlgorithms
import SwiftUI

extension PolicyCanvasQualityOverlayView {
  func drawPortSpacing(error: Color, warning: Color, dirtyRect: CGRect) {
    let errorRings = NSBezierPath()
    let warningRings = NSBezierPath()
    let detachedConnectors = NSBezierPath()
    let unevenArrows = NSBezierPath()
    let unevenGhosts = NSBezierPath()
    for violation in report.portSpacing {
      let markRect = portSpacingDirtyRect(for: violation)
      guard
        qualityMarkIntersectsDirtyRect(
          markRect,
          dirtyRect: dirtyRect,
          padding: 0
        )
      else {
        continue
      }
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
}
