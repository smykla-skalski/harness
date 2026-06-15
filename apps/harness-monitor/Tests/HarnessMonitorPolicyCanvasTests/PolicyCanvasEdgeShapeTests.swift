import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorPolicyCanvas
@testable import HarnessMonitorPolicyCanvasAlgorithms

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
    let kinds = pathElements(of: path)
    // move + line + quadCurve + line = 4 elements
    #expect(kinds.count == 4)
    #expect(kinds.contains(.quadCurve))
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
    let points = pathPoints(of: path)
    #expect(points.count >= 2)
    #expect(points[0] == CGPoint(x: 0, y: 0))
    #expect(points[1].x == 2)
    #expect(points[1].y == 0)
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
    let kinds = pathElements(of: path)
    let curveCount = kinds.filter { $0 == .quadCurve }.count
    // 5 points → 3 interior bends → 3 quad curves.
    #expect(curveCount == 3)
  }

  @Test("Label gap splits stroke path")
  func labelGapSplitsStrokePath() {
    let route = PolicyCanvasEdgeRoute(
      points: [CGPoint(x: 0, y: 0), CGPoint(x: 200, y: 0)],
      labelPosition: CGPoint(x: 100, y: 0)
    )
    let path = PolicyCanvasEdgeShape(
      route: route,
      gapFrames: [CGRect(x: 80, y: -10, width: 40, height: 20)]
    ).path(in: .zero)
    let points = pathPoints(of: path)

    #expect(
      points == [
        CGPoint(x: 0, y: 0),
        CGPoint(x: 80, y: 0),
        CGPoint(x: 120, y: 0),
        CGPoint(x: 200, y: 0),
      ])
  }

  @Test("Endpoint trim tucks rendered edge under port markers")
  func endpointTrimTucksRenderedEdgeUnderPortMarkers() {
    let route = PolicyCanvasEdgeRoute(
      points: [
        CGPoint(x: 0, y: 0),
        CGPoint(x: 100, y: 0),
        CGPoint(x: 100, y: 100),
      ],
      labelPosition: CGPoint(x: 100, y: 50)
    )

    let trimmed = policyCanvasEndpointTrimmedRoute(
      route,
      endpointInset: policyCanvasRenderedRouteEndpointInset()
    )

    #expect(trimmed.points.first == CGPoint(x: 7, y: 0))
    #expect(trimmed.points.last == CGPoint(x: 100, y: 93))
  }

  @Test("Arrowhead defaults render at readable canvas scale")
  func arrowheadDefaultsRenderAtReadableCanvasScale() {
    let route = PolicyCanvasEdgeRoute(
      points: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)],
      labelPosition: CGPoint(x: 50, y: 0)
    )

    let path = PolicyCanvasEdgeArrowhead(route: route).path(in: .zero)
    let points = pathPoints(of: path)

    #expect(
      points == [
        CGPoint(x: 100, y: 0),
        CGPoint(x: 88, y: 4.5),
        CGPoint(x: 88, y: -4.5),
      ])
  }
}

/// Drains a `Path`'s underlying `CGPath` into a kind-only summary. Uses
/// `CGPath.applyWithBlock` (the imperative C callback) rather than
/// `Path.forEach`, so the test bodies can iterate via a plain `for in`.
private enum PolicyCanvasPathKind {
  case move
  case line
  case quadCurve
  case curve
  case close
}

private func pathElements(of path: Path) -> [PolicyCanvasPathKind] {
  var kinds: [PolicyCanvasPathKind] = []
  path.cgPath.applyWithBlock { pointer in
    switch pointer.pointee.type {
    case .moveToPoint:
      kinds.append(.move)
    case .addLineToPoint:
      kinds.append(.line)
    case .addQuadCurveToPoint:
      kinds.append(.quadCurve)
    case .addCurveToPoint:
      kinds.append(.curve)
    case .closeSubpath:
      kinds.append(.close)
    @unknown default:
      break
    }
  }
  return kinds
}

private func pathPoints(of path: Path) -> [CGPoint] {
  var points: [CGPoint] = []
  path.cgPath.applyWithBlock { pointer in
    let element = pointer.pointee
    switch element.type {
    case .moveToPoint, .addLineToPoint:
      points.append(element.points[0])
    case .addQuadCurveToPoint:
      points.append(element.points[1])
    case .addCurveToPoint:
      points.append(element.points[2])
    case .closeSubpath:
      break
    @unknown default:
      break
    }
  }
  return points
}
