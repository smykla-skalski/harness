import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Policy canvas displayed routing")
@MainActor
struct PolicyCanvasDisplayedRoutingTests {
  @Test("default graph action routes avoid merge shapes")
  func defaultGraphActionRoutesAvoidMergeShapes() {
    let (viewModel, routes) = defaultDisplayedRoutes()

    guard
      let mergeGroup = viewModel.group("merge"),
      let defaultRoute = routes["edge:default"],
      let mutateRoute = routes["edge:mutate"],
      let unsafeRoute = routes["edge:unsafe"]
    else {
      Issue.record("Expected merge group and action routes")
      return
    }

    let mergeNodeFrames = viewModel.nodes
      .filter { $0.groupID == mergeGroup.id }
      .map { CGRect(origin: $0.position, size: PolicyCanvasLayout.nodeSize) }
    let mergeHardShapes = mergeNodeFrames + policyCanvasGroupTitleFrames([mergeGroup])
    for shape in mergeHardShapes {
      #expect(!defaultRoute.segmentsIntersect(rect: shape))
      #expect(!mutateRoute.segmentsIntersect(rect: shape))
      #expect(!unsafeRoute.segmentsIntersect(rect: shape))
    }
  }

  @Test("flex displayed routes attach to semantic visible port sides")
  func flexDisplayedRoutesAttachToSemanticVisiblePortSides() {
    let (viewModel, routes) = defaultDisplayedRoutes()

    for edge in viewModel.edges where !edge.effectivePinnedPortSide {
      guard let route = routes[edge.id] else {
        Issue.record("Expected route for \(edge.id)")
        return
      }

      #expect(
        viewModel.portAnchorCandidates(for: edge.source).containsSide(
          policyCanvasRouteSourceSide(route)))
      #expect(
        viewModel.portAnchorCandidates(for: edge.target).containsSide(
          policyCanvasRouteTargetSide(route)))
    }
  }

  @Test("routed port visibility hides unused duplicate sides")
  func routedPortVisibilityHidesUnusedDuplicateSides() {
    let (viewModel, routes) = defaultDisplayedRoutes()
    let visibility = policyCanvasPortVisibility(
      viewModel: viewModel,
      edges: viewModel.edges,
      routes: routes
    )

    guard let evidencePass = viewModel.edges.first(where: { $0.id == "edge:evidence-pass" }) else {
      Issue.record("Expected evidence-pass edge")
      return
    }

    #expect(
      policyCanvasVisiblePortSides(for: evidencePass.source, visibility: visibility) == [
        .bottom
      ])
    #expect(
      policyCanvasVisiblePortSides(for: evidencePass.target, visibility: visibility) == [
        .top
      ])

    let unconnectedActionInput = PolicyCanvasPortEndpoint(
      nodeID: "action:router",
      portID: "in",
      kind: .input
    )
    #expect(
      policyCanvasVisiblePortSides(for: unconnectedActionInput, visibility: visibility) == [
        .leading
      ])
  }

  @Test("default graph displayed routes do not share collision corridors")
  func defaultGraphDisplayedRoutesDoNotShareCollisionCorridors() {
    let (viewModel, routes) = defaultDisplayedRoutes()

    for leftIndex in viewModel.edges.indices {
      for rightIndex in viewModel.edges.index(after: leftIndex)..<viewModel.edges.endIndex {
        let left = viewModel.edges[leftIndex]
        let right = viewModel.edges[rightIndex]
        guard let leftRoute = routes[left.id], let rightRoute = routes[right.id] else {
          continue
        }
        if routesShareCollinearInterior(leftRoute, rightRoute) {
          #expect(left.id == right.id)
        }
      }
    }
  }

  @Test("default graph displayed routes do not render diagonal or nub segments")
  func defaultGraphDisplayedRoutesDoNotRenderDiagonalOrNubSegments() {
    let (viewModel, routes) = defaultDisplayedRoutes()
    let minimumSegmentLength = PolicyCanvasVisibilityRouter.channelStep * 2

    for edge in viewModel.edges {
      guard let route = routes[edge.id] else {
        continue
      }
      for (segmentIndex, segment) in zip(route.points, route.points.dropFirst()).enumerated() {
        let (start, end) = segment
        let dx = abs(end.x - start.x)
        let dy = abs(end.y - start.y)
        let length = dx + dy
        #expect(
          dx < 0.001 || dy < 0.001,
          "\(edge.id) rendered diagonal segment \(segmentIndex): \(start) -> \(end)"
        )
        if length > 0.001 {
          #expect(
            length >= minimumSegmentLength,
            "\(edge.id) rendered short segment \(segmentIndex): \(start) -> \(end)"
          )
        }
      }
    }
  }

  @Test("default graph evidence failure routes avoid seven-bend target doglegs")
  func defaultGraphEvidenceFailureRoutesAvoidSevenBendTargetDoglegs() {
    let (_, routes) = defaultDisplayedRoutes()

    guard let route = routes["edge:evidence-fail:unresolved-requested-changes"] else {
      Issue.record("Expected unresolved requested changes route")
      return
    }

    #expect(policyCanvasRouteMetrics(route).bends <= 5)
    #expect(policyCanvasRouteTargetSide(route) == .top)
  }

  @Test("default graph route interiors avoid node bodies")
  func defaultGraphRouteInteriorsAvoidNodeBodies() {
    let (viewModel, routes) = defaultDisplayedRoutes()
    let nodeBodies = viewModel.nodes.map { node in
      (
        id: node.id,
        frame: CGRect(origin: node.position, size: PolicyCanvasLayout.nodeSize)
          .insetBy(dx: 0.5, dy: 0.5)
      )
    }

    for edge in viewModel.edges {
      guard let route = routes[edge.id] else {
        continue
      }
      for segment in policyCanvasInteriorSegments(route) {
        for node in nodeBodies where segment.intersects(node.frame) {
          #expect(Bool(false), "\(edge.id) interior segment crosses \(node.id)")
        }
      }
    }
  }

  @Test("route worker matches displayed routing semantics")
  func routeWorkerMatchesDisplayedRoutingSemantics() async {
    let (viewModel, expectedRoutes) = defaultDisplayedRoutes()
    let input = PolicyCanvasRouteWorkerInput(
      nodes: viewModel.nodes,
      groups: viewModel.groups,
      edges: viewModel.edges,
      fontScale: 1
    )
    let output = await PolicyCanvasRouteWorker(router: PolicyCanvasVisibilityRouter())
      .compute(input: input)

    #expect(output.routes.keys.sorted() == expectedRoutes.keys.sorted())
    for edge in viewModel.edges {
      #expect(
        output.routes[edge.id]?.points == expectedRoutes[edge.id]?.points,
        "worker route for \(edge.id) diverged from displayed route helper"
      )
    }
    #expect(
      output.portVisibility
        == policyCanvasPortVisibility(
          viewModel: viewModel,
          edges: viewModel.edges,
          routes: expectedRoutes
        )
    )
  }

  private func defaultDisplayedRoutes() -> (
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

  private func routesShareCollinearInterior(
    _ left: PolicyCanvasEdgeRoute,
    _ right: PolicyCanvasEdgeRoute
  ) -> Bool {
    policyCanvasInteriorSegments(left).contains { leftSegment in
      policyCanvasInteriorSegments(right).contains { rightSegment in
        leftSegment.sharesCollinearRange(with: rightSegment)
      }
    }
  }

  private func policyCanvasInteriorSegments(
    _ route: PolicyCanvasEdgeRoute
  ) -> [PolicyCanvasDisplayedRouteTestSegment] {
    let segments = Array(zip(route.points, route.points.dropFirst()))
    guard segments.count > 2 else {
      return []
    }
    return segments.enumerated().compactMap { index, segment in
      guard index > 0, index < segments.count - 1 else {
        return nil
      }
      return PolicyCanvasDisplayedRouteTestSegment(start: segment.0, end: segment.1)
    }
  }
}

extension [PolicyCanvasRouteAnchorCandidate] {
  fileprivate func containsSide(_ side: PolicyCanvasPortSide?) -> Bool {
    guard let side else {
      return false
    }
    return contains { candidate in candidate.side == side }
  }
}

private struct PolicyCanvasDisplayedRouteTestSegment {
  let start: CGPoint
  let end: CGPoint

  var isHorizontal: Bool {
    abs(start.y - end.y) < 0.001
  }

  var isVertical: Bool {
    abs(start.x - end.x) < 0.001
  }

  func sharesCollinearRange(with other: PolicyCanvasDisplayedRouteTestSegment) -> Bool {
    if isHorizontal, other.isHorizontal, abs(start.y - other.start.y) < 0.001 {
      return overlap(
        min(start.x, end.x)...max(start.x, end.x),
        min(other.start.x, other.end.x)...max(other.start.x, other.end.x)
      ) > 0.001
    }
    if isVertical, other.isVertical, abs(start.x - other.start.x) < 0.001 {
      return overlap(
        min(start.y, end.y)...max(start.y, end.y),
        min(other.start.y, other.end.y)...max(other.start.y, other.end.y)
      ) > 0.001
    }
    return false
  }

  func intersects(_ rect: CGRect) -> Bool {
    if isHorizontal {
      let xRange = min(start.x, end.x)...max(start.x, end.x)
      return rect.minY < start.y && rect.maxY > start.y
        && overlap(xRange, rect.minX...rect.maxX) > 0.001
    }
    if isVertical {
      let yRange = min(start.y, end.y)...max(start.y, end.y)
      return rect.minX < start.x && rect.maxX > start.x
        && overlap(yRange, rect.minY...rect.maxY) > 0.001
    }
    return false
  }

  private func overlap(_ left: ClosedRange<CGFloat>, _ right: ClosedRange<CGFloat>) -> CGFloat {
    max(0, min(left.upperBound, right.upperBound) - max(left.lowerBound, right.lowerBound))
  }
}
