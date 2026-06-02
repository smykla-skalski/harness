import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorPolicyCanvas
@testable import HarnessMonitorPolicyCanvasAlgorithms

extension PolicyCanvasRoutingScreenshotRegressionTests {
  func defaultDisplayedRoutes() -> (
    viewModel: PolicyCanvasViewModel,
    routes: [String: PolicyCanvasEdgeRoute]
  ) {
    let document = PreviewFixtures.policyCanvasPipelineDocument()
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.load(document: document, simulation: nil, audit: nil)
    let edges = viewModel.edges
    return (
      viewModel: viewModel,
      routes: policyCanvasDisplayedRoutes(
        viewModel: viewModel,
        edges: edges,
        portAnchors: viewModel.portAnchors(for: edges),
        router: PolicyCanvasVisibilityRouter()
      )
    )
  }

  func defaultPreparedDisplayedRoutes() -> (
    viewModel: PolicyCanvasViewModel,
    routes: [String: PolicyCanvasEdgeRoute]
  ) {
    let document = PreviewFixtures.policyCanvasPipelineDocument()
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.load(document: document, simulation: nil, audit: nil)
    let edges = viewModel.edges
    let input = PolicyCanvasRouteWorkerInput(
      nodes: viewModel.nodes,
      groups: viewModel.groups,
      edges: edges,
      fontScale: 1,
      routingHints: viewModel.routingHints
    )
    let prepared = PolicyCanvasPreparedRouteInput(input: input)
    let router = PolicyCanvasMemoizedRouter(inner: PolicyCanvasVisibilityRouter())
    let nodeIndex = prepared.nodeIndex
    let initialRoutes = prepared.displayedRoutes(router: router)
    var portMarkerLayout = prepared.portMarkerLayout(
      routes: initialRoutes,
      nodeIndex: nodeIndex
    )
    var routes = initialRoutes
    var converged = false
    for _ in 0..<3 {
      routes = prepared.displayedRoutes(
        router: router,
        portMarkerLayout: portMarkerLayout
      )
      let nextPortMarkerLayout = prepared.portMarkerLayout(
        routes: routes,
        nodeIndex: nodeIndex
      )
      if nextPortMarkerLayout == portMarkerLayout {
        converged = true
        break
      }
      portMarkerLayout = nextPortMarkerLayout
    }
    if !converged {
      routes = prepared.displayedRoutes(
        router: router,
        portMarkerLayout: portMarkerLayout
      )
    }
    return (
      viewModel: viewModel,
      routes: routes
    )
  }

  func dominantSharedHorizontalTrunkY(
    routes: [PolicyCanvasEdgeRoute]
  ) -> CGFloat? {
    let sharedSegments = routes.enumerated().flatMap { leftIndex, leftRoute in
      routes[(leftIndex + 1)...].flatMap { rightRoute -> [SharedHorizontalTrunk] in
        horizontalSegments(leftRoute).compactMap { leftSegment in
          horizontalSegments(rightRoute).compactMap { rightSegment in
            leftSegment.sharedTrunk(with: rightSegment)
          }
        }.flatMap { $0 }
      }
    }
    return sharedSegments.max(by: { $0.overlap < $1.overlap })?.y
  }

  func horizontalSegments(_ route: PolicyCanvasEdgeRoute) -> [HorizontalSegment] {
    zip(route.points, route.points.dropFirst()).compactMap { start, end in
      HorizontalSegment(start: start, end: end)
    }
  }

  func finalHorizontalSegmentBeforeTarget(_ route: PolicyCanvasEdgeRoute)
    -> HorizontalSegment?
  {
    guard route.points.count >= 3 else {
      return nil
    }
    return HorizontalSegment(
      start: route.points[route.points.count - 3],
      end: route.points[route.points.count - 2]
    )
  }

  func assertRouteUsesPreferredVerticalCorridor(_ edgeID: String) {
    let (viewModel, routes) = defaultDisplayedRoutes()
    guard let routingHints = viewModel.routingHints else {
      Issue.record("Expected routing hints for the default policy graph")
      return
    }

    let edge = viewModel.edges.first(where: { $0.id == edgeID })
    #expect(edge != nil, "Expected edge for \(edgeID)")
    let route = routes[edgeID]
    #expect(route != nil, "Expected displayed route for \(edgeID)")
    let hint = routingHints.edgeHint(for: edgeID)
    #expect(hint != nil, "Expected routing hint for \(edgeID)")
    let preferredX = hint?.verticalLaneX
    #expect(
      preferredX != nil,
      "\(edgeID) should expose a preferred vertical corridor; hint \(String(describing: hint))"
    )
    let laneX = route.flatMap(policyCanvasDominantVerticalLaneCoordinate)
    #expect(
      laneX != nil,
      "\(edgeID) should expose a dominant vertical lane; route \(String(describing: route?.points))"
    )
    guard
      let edge,
      let route,
      let preferredX,
      let laneX
    else {
      return
    }

    let tolerance = max(
      PolicyCanvasLayout.gridSize,
      viewModel.edgeLineSpacing(for: edge) * 2
    )
    if abs(laneX - preferredX) <= tolerance {
      return
    }
    // A horizontally-dominant route to a far target legitimately does not
    // capture its vertical corridor. The router only forces the corridor for
    // vertically-dominant routes (verticalSpan >= 2 * horizontalSpan in
    // policyCanvasAlignedVerticalDominantCorridorRoute); a wide, shallow route
    // drops at whatever lane keeps it clear of its fan siblings. That is still
    // a clean route as long as its dominant vertical lane stays inside its own
    // source -> target horizontal span rather than backtracking outside it.
    let sourceX = route.points.first?.x ?? laneX
    let targetX = route.points.last?.x ?? laneX
    let sourceY = route.points.first?.y ?? 0
    let targetY = route.points.last?.y ?? 0
    let horizontallyDominant = abs(targetX - sourceX) > abs(targetY - sourceY)
    let span = min(sourceX, targetX)...max(sourceX, targetX)
    #expect(
      horizontallyDominant && span.contains(laneX),
      """
      \(edgeID) vertical lane \(laneX) should stay near preferred corridor \
      \(preferredX), or for a horizontal route stay inside its source-target \
      span \(span); route \(route.points)
      """
    )
  }

  func defaultNodeAndGroupFrames(viewModel: PolicyCanvasViewModel) -> [CGRect] {
    viewModel.nodes.map {
      CGRect(origin: $0.position, size: PolicyCanvasLayout.nodeSize)
    } + policyCanvasGroupTitleFrames(viewModel.groups)
  }

  func labelPlacementRoutes(
    for edgeIDs: [String],
    viewModel: PolicyCanvasViewModel,
    routes: [String: PolicyCanvasEdgeRoute],
    metrics: PolicyCanvasEdgeLabelMetrics
  ) -> [PolicyCanvasLabelPlacementRoute] {
    edgeIDs.compactMap { edgeID in
      guard
        let route = routes[edgeID],
        let edge = viewModel.edges.first(where: { $0.id == edgeID })
      else {
        return nil
      }
      return PolicyCanvasLabelPlacementRoute(
        id: edgeID,
        label: edge.label,
        route: route,
        size: metrics.size(for: edge.label)
      )
    }
  }

  func actionTerminalRoutes(
    _ routes: [String: PolicyCanvasEdgeRoute]
  ) -> [(id: String, route: PolicyCanvasEdgeRoute)] {
    Self.actionTerminalEdgeIDs.compactMap { edgeID in
      routes[edgeID].map { (id: edgeID, route: $0) }
    }
  }

  func riskFamilyRoutes(
    _ routes: [String: PolicyCanvasEdgeRoute]
  ) -> [(id: String, route: PolicyCanvasEdgeRoute)] {
    Self.riskFamilyEdgeIDs.compactMap { edgeID in
      routes[edgeID].map { (id: edgeID, route: $0) }
    }
  }

  func maximumSharedInteriorOverlap(routes: [PolicyCanvasEdgeRoute]) -> CGFloat {
    routes.enumerated().reduce(CGFloat.zero) { currentMax, leftEntry in
      let (leftIndex, leftRoute) = leftEntry
      let leftSegments = interiorSegments(leftRoute).filter(\.isHorizontal)
      let pairMax = routes[(leftIndex + 1)...].reduce(CGFloat.zero) { pairCurrentMax, rightRoute in
        let rightSegments = interiorSegments(rightRoute).filter(\.isHorizontal)
        let overlap = leftSegments.reduce(CGFloat.zero) { overlapMax, leftSegment in
          rightSegments.reduce(overlapMax) { segmentMax, rightSegment in
            max(segmentMax, leftSegment.sharedOverlap(with: rightSegment))
          }
        }
        return max(pairCurrentMax, overlap)
      }
      return max(currentMax, pairMax)
    }
  }

  func interiorSegments(_ route: PolicyCanvasEdgeRoute) -> [DisplayedRouteSegment] {
    let segments = Array(zip(route.points, route.points.dropFirst()))
    guard segments.count > 2 else {
      return []
    }
    return segments.enumerated().compactMap { index, segment in
      guard index > 0, index < segments.count - 1 else {
        return nil
      }
      return DisplayedRouteSegment(start: segment.0, end: segment.1)
    }
  }

  func rightmostSharedVerticalTrunk(routes: [PolicyCanvasEdgeRoute]) -> SharedVerticalTrunk? {
    let sharedSegments = routes.enumerated().flatMap { leftIndex, leftRoute in
      routes[(leftIndex + 1)...].flatMap { rightRoute -> [SharedVerticalTrunk] in
        verticalSegments(leftRoute).compactMap { leftSegment in
          verticalSegments(rightRoute).compactMap { rightSegment in
            leftSegment.sharedTrunk(with: rightSegment)
          }
        }.flatMap { $0 }
      }
    }
    return sharedSegments.max { left, right in
      if abs(left.x - right.x) > 0.001 {
        return left.x < right.x
      }
      return left.overlap < right.overlap
    }
  }

  func verticalSegments(_ route: PolicyCanvasEdgeRoute) -> [VerticalSegment] {
    zip(route.points, route.points.dropFirst()).compactMap { start, end in
      VerticalSegment(start: start, end: end)
    }
  }

  func labelFrame(center: CGPoint, size: CGSize) -> CGRect {
    CGRect(
      x: center.x - (size.width / 2),
      y: center.y - (size.height / 2),
      width: size.width,
      height: size.height
    )
  }

  func verticalTrunkFrame(_ trunk: SharedVerticalTrunk) -> CGRect {
    CGRect(
      x: trunk.x - PolicyCanvasLayout.gridSize,
      y: trunk.range.lowerBound,
      width: PolicyCanvasLayout.gridSize * 2,
      height: trunk.range.upperBound - trunk.range.lowerBound
    )
  }
}

struct SharedHorizontalTrunk {
  let y: CGFloat
  let overlap: CGFloat
}

struct SharedVerticalTrunk {
  let x: CGFloat
  let range: ClosedRange<CGFloat>
  let overlap: CGFloat
}

struct HorizontalSegment {
  let start: CGPoint
  let end: CGPoint

  var length: CGFloat {
    abs(end.x - start.x)
  }

  init?(start: CGPoint, end: CGPoint) {
    guard abs(start.y - end.y) < 0.001, abs(start.x - end.x) > 0.001 else {
      return nil
    }
    self.start = start
    self.end = end
  }

  func sharedTrunk(with other: Self) -> SharedHorizontalTrunk? {
    guard abs(start.y - other.start.y) < 0.001 else {
      return nil
    }
    let overlap = max(
      0,
      min(max(start.x, end.x), max(other.start.x, other.end.x))
        - max(min(start.x, end.x), min(other.start.x, other.end.x))
    )
    guard overlap > 0.001 else {
      return nil
    }
    return SharedHorizontalTrunk(y: start.y, overlap: overlap)
  }
}

struct VerticalSegment {
  let start: CGPoint
  let end: CGPoint

  init?(start: CGPoint, end: CGPoint) {
    guard abs(start.x - end.x) < 0.001, abs(start.y - end.y) > 0.001 else {
      return nil
    }
    self.start = start
    self.end = end
  }

  func sharedTrunk(with other: Self) -> SharedVerticalTrunk? {
    guard abs(start.x - other.start.x) < 0.001 else {
      return nil
    }
    let lowerBound = max(min(start.y, end.y), min(other.start.y, other.end.y))
    let upperBound = min(max(start.y, end.y), max(other.start.y, other.end.y))
    let overlap = max(0, upperBound - lowerBound)
    guard overlap > 0.001 else {
      return nil
    }
    return SharedVerticalTrunk(
      x: start.x,
      range: lowerBound...upperBound,
      overlap: overlap
    )
  }
}

struct DisplayedRouteSegment {
  let start: CGPoint
  let end: CGPoint

  var isHorizontal: Bool {
    abs(start.y - end.y) < 0.001
  }

  var isVertical: Bool {
    abs(start.x - end.x) < 0.001
  }

  func sharedOverlap(with other: Self) -> CGFloat {
    if isHorizontal, other.isHorizontal, abs(start.y - other.start.y) < 0.001 {
      return overlap(
        min(start.x, end.x)...max(start.x, end.x),
        min(other.start.x, other.end.x)...max(other.start.x, other.end.x)
      )
    }
    if isVertical, other.isVertical, abs(start.x - other.start.x) < 0.001 {
      return overlap(
        min(start.y, end.y)...max(start.y, end.y),
        min(other.start.y, other.end.y)...max(other.start.y, other.end.y)
      )
    }
    return 0
  }

  private func overlap(_ left: ClosedRange<CGFloat>, _ right: ClosedRange<CGFloat>) -> CGFloat {
    max(0, min(left.upperBound, right.upperBound) - max(left.lowerBound, right.lowerBound))
  }
}
