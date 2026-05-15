import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Policy canvas edge shape - corner filleting")
struct PolicyCanvasEdgeShapeTests {
  @Test("Empty route produces empty path")
  func emptyRouteIsEmpty() {
    let route = PolicyCanvasEdgeRoute(points: [], labelPosition: .zero)
    let path = PolicyCanvasEdgeShape(route: route).path(in: .zero)
    #expect(path.isEmpty)
  }

  @Test("Two-point route renders a straight line")
  func twoPointRouteIsStraight() {
    let route = PolicyCanvasEdgeRoute(
      points: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)],
      labelPosition: CGPoint(x: 50, y: 0)
    )
    let path = PolicyCanvasEdgeShape(route: route).path(in: .zero)
    #expect(path.boundingRect.width == 100)
    #expect(path.boundingRect.height == 0)
  }

  @Test("Single-bend route fillets the bend")
  func singleBendRouteFillets() {
    let route = PolicyCanvasEdgeRoute(
      points: [
        CGPoint(x: 0, y: 0),
        CGPoint(x: 100, y: 0),
        CGPoint(x: 100, y: 100),
      ],
      labelPosition: CGPoint(x: 100, y: 50)
    )
    let shape = PolicyCanvasEdgeShape(route: route, cornerRadius: 8)
    let path = shape.path(in: .zero)
    var elements: [Path.Element] = []
    path.forEach { elements.append($0) }
    // move + line + quadCurve + line = 4 elements
    #expect(elements.count == 4)
    var sawQuadCurve = false
    for element in elements {
      if case .quadCurve = element {
        sawQuadCurve = true
      }
    }
    #expect(sawQuadCurve)
  }

  @Test("Corner radius clips to half the shorter neighbor segment")
  func cornerRadiusClipsToHalfSegment() {
    let route = PolicyCanvasEdgeRoute(
      points: [
        CGPoint(x: 0, y: 0),
        CGPoint(x: 4, y: 0),
        CGPoint(x: 4, y: 100),
      ],
      labelPosition: CGPoint(x: 4, y: 50)
    )
    let shape = PolicyCanvasEdgeShape(route: route, cornerRadius: 10)
    let path = shape.path(in: .zero)
    // The first segment is 4pt long, so radius clips to 2.
    // The fillet should start at x=2 (4 - 2*1) before the corner.
    var encountered: [CGPoint] = []
    path.forEach { element in
      switch element {
      case .move(let to): encountered.append(to)
      case .line(let to): encountered.append(to)
      case .quadCurve(let to, _): encountered.append(to)
      default: break
      }
    }
    // First two encountered points: (0,0), (2,0).
    #expect(encountered.count >= 2)
    #expect(encountered[0] == CGPoint(x: 0, y: 0))
    #expect(encountered[1].x == 2)
    #expect(encountered[1].y == 0)
  }

  @Test("Multi-bend route emits one curve per interior bend")
  func multiBendRouteFilletsEachBend() {
    let route = PolicyCanvasEdgeRoute(
      points: [
        CGPoint(x: 0, y: 0),
        CGPoint(x: 100, y: 0),
        CGPoint(x: 100, y: 100),
        CGPoint(x: 200, y: 100),
        CGPoint(x: 200, y: 200),
      ],
      labelPosition: CGPoint(x: 150, y: 100)
    )
    let shape = PolicyCanvasEdgeShape(route: route, cornerRadius: 6)
    let path = shape.path(in: .zero)
    var curveCount = 0
    path.forEach { element in
      if case .quadCurve = element {
        curveCount += 1
      }
    }
    // 5 points → 3 interior bends → 3 quad curves.
    #expect(curveCount == 3)
  }
}
