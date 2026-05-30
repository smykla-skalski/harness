import SwiftUI

/// Marquee selection mode for Policy Canvas
enum PolicyCanvasMarqueeSelectionMode: Sendable {
  case replace
  case add
  case remove
}

/// State for an active marquee selection gesture
struct PolicyCanvasMarqueeSelectionState: Sendable {
  let anchor: CGPoint
  let current: CGPoint
  let mode: PolicyCanvasMarqueeSelectionMode

  /// Normalized rectangle from anchor to current, always with positive width/height
  var rect: CGRect {
    let minX = min(anchor.x, current.x)
    let minY = min(anchor.y, current.y)
    let maxX = max(anchor.x, current.x)
    let maxY = max(anchor.y, current.y)
    return CGRect(
      x: minX,
      y: minY,
      width: maxX - minX,
      height: maxY - minY
    )
  }
}

/// Hit resolver for marquee selection
enum PolicyCanvasMarqueeSelectionHitResolver {
  /// Returns the set of selections captured by the marquee rectangle
  static func capturedSelections(
    marqueeRect: CGRect,
    nodes: [PolicyCanvasNode],
    groups: [PolicyCanvasGroup],
    edges: [PolicyCanvasEdge],
    routes: [String: PolicyCanvasEdgeRoute]
  ) -> Set<PolicyCanvasSelection> {
    var captured = Set<PolicyCanvasSelection>()

    // Capture nodes whose frames intersect the marquee
    for node in nodes {
      let nodeFrame = policyCanvasNodeFrame(node)
      if marqueeRect.intersects(nodeFrame) {
        captured.insert(.node(node.id))
      }
    }

    // Capture groups whose frames intersect the marquee
    for group in groups where marqueeRect.intersects(group.frame) {
      captured.insert(.group(group.id))
    }

    // Capture edges whose route segment frames intersect the marquee
    for edge in edges {
      guard let route = routes[edge.id] else {
        continue
      }
      let segmentFrames = policyCanvasRouteSegmentFrames(route)
      if segmentFrames.contains(where: { marqueeRect.intersects($0) }) {
        captured.insert(.edge(edge.id))
      }
    }

    return captured
  }
}
